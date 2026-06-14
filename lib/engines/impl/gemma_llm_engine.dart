/// The on-device [LlmEngine]: Gemma 4 E2B running through LiteRT-LM on a
/// background isolate.
///
/// This class is only a state machine. Every plugin call lives in
/// `GemmaRuntime`, and every isolate detail lives in `IsolateInferenceHost`, so what
/// is left here is the part upstream code actually depends on: when the engine is
/// ready, what a turn looks like, and what happens when one fails. That is also why
/// it takes an [InferenceHost] rather than building one — the contract is verified on
/// the host, and the device tests then only have to prove the *device* part.
library;

import 'dart:async';

import '../../services/inference/inference_config.dart';
import '../../services/inference/inference_isolate.dart';
import '../tool_schema.dart';
import '../llm_engine.dart';

/// [LlmEngine] backed by real weights on the device.
class GemmaLlmEngine implements LlmEngine {
  GemmaLlmEngine({required this.config, InferenceHost? host})
    // Defaulted rather than required so production code reads
    // `GemmaLlmEngine(config: …)` and only tests name a host.
    : _host = host ?? IsolateInferenceHost();

  /// The configuration this engine was built with — notably the model path, which
  /// is what makes a load failure ("no such file") diagnosable from the outside.
  final InferenceConfig config;

  final InferenceHost _host;

  LoadedRuntime? _runtime;

  /// In-flight load, so overlapping `initialize()` calls share one model load.
  ///
  /// Not a nicety: the readiness banner and a "Diagnose" tap can both want the
  /// engine, and a second load of a 2.6GB model would either double the resident
  /// footprint or fail — the same class of bug Task 1.7's provisioner had to
  /// serialise away. One future, shared.
  Future<LoadedRuntime>? _loading;

  bool _disposed = false;

  @override
  bool get isReady => _runtime != null && !_disposed;

  /// What the runtime reported at load: backend, load time, context window.
  ///
  /// Null until [initialize] completes. Exposed because these are the numbers the
  /// spike exists to produce, and a measurement nothing can read is a measurement
  /// nobody will check.
  LoadedRuntime? get runtime => _runtime;

  @override
  Future<void> initialize() async {
    if (_disposed) {
      throw StateError('GemmaLlmEngine was disposed; create a new instance');
    }
    if (_runtime != null) return;
    // Idempotent by sharing the in-flight future rather than by returning early:
    // returning early would let a second caller proceed as if the model were
    // resident while the first load is still running.
    _loading ??= _host.start(config);
    try {
      _runtime = await _loading;
    } finally {
      _loading = null;
    }
  }

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) {
    if (_disposed) {
      throw StateError('GemmaLlmEngine was disposed');
    }
    if (!isReady) {
      // Same failure mode as the fake, which throws when generate precedes
      // initialize. Matching it matters: the agent loop is written against one
      // contract and tested against the fake.
      throw StateError('GemmaLlmEngine.generate called before initialize()');
    }
    // Validated here, at the app-facing entry, rather than deeper down: this throws
    // *synchronously at the caller's call site*, where the malformed tool was
    // registered, instead of arriving later as an async failure from a worker
    // isolate. It also means the rule is bound by host tests — the runtime that
    // ultimately renders the schema needs a model, so a check living only there
    // could not be tested without a device.
    assertToolDefinitionsUsable(tools);
    return _host.generate(prompt: prompt, tools: tools);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _runtime = null;
    // A dispose racing an in-flight load must not leave the worker holding weights
    // nobody will ever use, so the load is awaited out (failure and success alike)
    // before the host is torn down.
    final loading = _loading;
    _loading = null;
    if (loading != null) {
      try {
        await loading;
      } on Object {
        // Whatever went wrong with a load whose result is now unwanted is not worth
        // propagating out of dispose; the shutdown below is what matters.
      }
    }
    await _host.shutdown();
  }
}
