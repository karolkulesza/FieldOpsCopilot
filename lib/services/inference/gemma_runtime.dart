/// The only file in this app that talks to `flutter_gemma`.
///
/// Everything above it speaks `LlmEngine` / `LlmEvent` (Task 0.2) and this file is
/// where those meet the plugin's `InferenceModel` / `InferenceChat` / `ModelResponse`
/// vocabulary. Concentrating the dependency in one place is what makes the low-RAM
/// model swap, and any future runtime swap, a change to this file only.
///
/// It is written to run **inside the inference isolate** (see
/// `inference_isolate.dart`), so it does no UI work and holds no Riverpod state.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import '../../engines/llm_engine.dart';
import 'inference_config.dart';
import 'tool_schema.dart';

/// What the inference worker drives. Exists so the worker's protocol handling can
/// be tested against a scripted runtime instead of a 2.6GB model.
abstract interface class InferenceRuntime {
  /// Loads the weights and reports what the runtime actually gave us.
  Future<LoadedRuntime> load(InferenceConfig config);

  /// Runs one stateless turn, streaming tokens and tool calls, terminated by
  /// [LlmDone].
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools,
  });

  /// Stops the turn currently generating, if any.
  Future<void> stop();

  /// Releases the model and native resources.
  Future<void> close();
}

/// `flutter_gemma` + `flutter_gemma_litertlm` behind [InferenceRuntime].
///
/// Three plugin facts drive the shape of this class, and each one is a silent
/// failure if you get it wrong:
///
/// 1. **Engines are opt-in.** `flutter_gemma` 1.x registers no inference engine of
///    its own, so `.litertlm` support only exists once [LiteRtLmEngine] is passed to
///    `FlutterGemma.initialize`. Without it the first model creation throws.
/// 2. **`supportsFunctionCalls` gates the tool calls, not the tools.** Passing
///    `tools:` alone gets the declaration in front of the model, but
///    `InferenceChat` only *reads back* the structured calls when
///    `supportsFunctionCalls` is true. Miss it and the model dutifully emits a tool
///    call that is discarded, which looks exactly like a model that will not call
///    tools.
/// 3. **A chat's tools are fixed when its session is created.** For Gemma 4 they
///    become the SDK's `tools_json` at conversation-creation time, so a chat cannot
///    be reused for a turn with a different tool set. Hence one chat per turn — see
///    [generate].
class GemmaRuntime implements InferenceRuntime {
  GemmaRuntime();

  InferenceModel? _model;
  InferenceChat? _chat;
  InferenceConfig? _config;

  /// Guards `FlutterGemma.initialize`, which is per-isolate global state.
  ///
  /// Not `static`: this object's whole lifetime is one isolate, and a static flag
  /// would be the same per-isolate-versus-process confusion that bit Task 1.7's
  /// staging nonce. An instance field says what it means — this runtime initialised
  /// the plugin it is using.
  bool _pluginInitialized = false;

  @override
  Future<LoadedRuntime> load(InferenceConfig config) async {
    if (_model != null) {
      throw StateError(
        'GemmaRuntime.load called twice; close() the runtime first',
      );
    }
    final stopwatch = Stopwatch()..start();

    if (!_pluginInitialized) {
      // Release builds are silent regardless; in debug this keeps prompts and model
      // output out of the log unless someone deliberately turns them up. The
      // grounded prompt carries customer-site text, and §3.2 of the spec is
      // explicit that it must not leak off-device — a log line is a leak.
      FlutterGemma.logLevel = GemmaLogLevel.info;
      await FlutterGemma.initialize(inferenceEngines: const [LiteRtLmEngine()]);
      _pluginInitialized = true;
    }

    // `fromFile` *registers* the path — it copies nothing. That matters: the
    // artifact is 2.6GB and Task 1.7 already placed it in no-backup application
    // support after verifying its SHA-256, so a copy would double the footprint and
    // create a second file nothing has hashed. The plugin marks it protected so its
    // own cleanup never deletes weights it did not download.
    await FlutterGemma.installModel(
      modelType: _modelTypeFor(config.family),
      fileType: ModelFileType.litertlm,
    ).fromFile(config.modelPath).install();

    final model = await FlutterGemma.getActiveModel(
      maxTokens: config.contextTokens,
      preferredBackend: _backendFor(config.backend),
    );

    _model = model;
    _config = config;
    stopwatch.stop();

    final runtime = LoadedRuntime(
      // Reported, never assumed: the FFI engine falls back from the requested
      // accelerator on its own (no Metal on the iOS simulator, for one), and the
      // spike's numbers are meaningless without knowing which backend produced
      // them.
      backend: model.activeBackend?.name ?? LoadedRuntime.unknownBackend,
      loadMillis: stopwatch.elapsedMilliseconds,
      // The engine clamps a context window below the bundle's baked KV-cache
      // length, so this is what it settled on rather than what we asked for.
      contextTokens: model.maxTokens,
    );
    debugPrint('[GemmaRuntime] loaded: $runtime');
    return runtime;
  }

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) async* {
    final model = _model;
    final config = _config;
    if (model == null || config == null) {
      throw StateError('GemmaRuntime.generate called before load()');
    }
    // Fail here rather than let a malformed declaration reach the model, where it
    // degrades into "a tool with no arguments" and reads as a model failure.
    assertToolDefinitionsUsable(tools);

    // One chat per turn. Two reasons, both load-bearing:
    //   * a chat's tools are baked into its session at creation (see the class
    //     doc), so a per-turn tool set needs a per-turn session; and
    //   * `LlmEngine.generate` is a *stateless* turn — the fake behaves that way and
    //     the golden suite depends on it — so history from turn N must not leak into
    //     N+1. Task 1.9 owns multi-turn tool round-trips and will extend the
    //     interface rather than quietly inherit a chat's accumulated history.
    // The cost is one conversation create, not a model load: the weights stay
    // resident in `_model` across turns.
    final chat = await model.createChat(
      temperature: config.temperature,
      topK: config.topK,
      randomSeed: config.randomSeed,
      tools: [for (final tool in tools) _toolFor(tool)],
      // Without this the structured calls are parsed and then dropped. See the
      // class doc, point 2.
      supportsFunctionCalls: tools.isNotEmpty,
      maxOutputTokens: config.maxOutputTokens,
      // `modelType` is deliberately not passed: it defaults to the type the loaded
      // spec carries, and naming it here would let a config drift from the weights
      // that are actually resident.
    );
    _chat = chat;

    try {
      await chat.addQuery(Message.text(text: prompt, isUser: true));
      await for (final response in chat.generateChatResponseAsync()) {
        for (final event in llmEventsFor(response)) {
          yield event;
        }
      }
      _logTurnMetrics(chat);
      yield const LlmDone();
    } finally {
      _chat = null;
      // Frees this turn's KV cache. Leaving sessions open across turns is how a
      // multi-gigabyte model OOMs a phone: each one holds its own context.
      await chat.close();
    }
  }

  @override
  Future<void> stop() async {
    // A stop for a turn that already finished is normal (the request and the last
    // token race), and the plugin's cancel is idempotent, so a null chat is a no-op
    // rather than an error.
    await _chat?.stopGeneration();
  }

  @override
  Future<void> close() async {
    final chat = _chat;
    _chat = null;
    // Order matters: the session must go before the model, because closing the
    // model deletes the native engine the session's conversation points into.
    await chat?.close();
    final model = _model;
    _model = null;
    _config = null;
    await model?.close();
  }

  void _logTurnMetrics(InferenceChat chat) {
    // Measurements are the deliverable of this spike, so the engine's own numbers
    // are logged next to the wall-clock ones the tests take at the app boundary.
    // They answer different questions: this is what the accelerator did, the test's
    // is what a technician waits for.
    try {
      final metrics = chat.session.getSessionMetrics();
      debugPrint('[GemmaRuntime] turn metrics: $metrics');
    } on Object catch (error) {
      // Metrics are diagnostics. A backend that does not report them must never
      // fail a turn that produced a perfectly good answer.
      debugPrint('[GemmaRuntime] session metrics unavailable: $error');
    }
  }

  static ModelType _modelTypeFor(GemmaModelFamily family) => switch (family) {
    // Selects the SDK's native function-calling path: tool declarations are
    // rendered into `<|tool>` tokens and calls come back as structured events.
    GemmaModelFamily.gemma4 => ModelType.gemma4,
    // Gemma 3 has no native tool tokens; the plugin injects a textual declaration
    // and parses JSON back out of the generated text. Same `LlmToolCall` upstream.
    GemmaModelFamily.gemma3 => ModelType.gemmaIt,
  };

  static PreferredBackend? _backendFor(
    InferenceBackend backend,
  ) => switch (backend) {
    // `null` is not "no backend" — it is "engine's choice", which lets its own
    // fallback chain run instead of pinning a backend that may not exist here.
    InferenceBackend.auto => null,
    InferenceBackend.cpu => PreferredBackend.cpu,
    InferenceBackend.gpu => PreferredBackend.gpu,
    InferenceBackend.npu => PreferredBackend.npu,
  };

  static Tool _toolFor(ToolDefinition definition) => Tool(
    name: definition.name,
    description: definition.description,
    // Passed through unchanged: `ToolDefinition.parameters` is already required to
    // be the JSON-Schema object the plugin wants (see `tool_schema.dart`), and this
    // is the reason that contract is enforced rather than guessed at.
    parameters: definition.parameters,
  );
}

/// Translates one plugin response into zero or more [LlmEvent]s.
///
/// Pure and top-level so the mapping — the part most likely to break when the
/// plugin's response hierarchy grows — is unit-testable on the host without a model,
/// an isolate or a device.
///
/// Returns a list because one plugin response can be several events: Gemma 4 can
/// emit parallel tool calls in a single turn, and flattening them here means the
/// agent loop only ever deals with one call per event.
List<LlmEvent> llmEventsFor(ModelResponse response) => switch (response) {
  // Empty chunks carry no information and would show up as spurious stream items
  // in the golden snapshots; the FFI layer already suppresses most of them.
  TextResponse(:final token) => token.isEmpty ? const [] : [LlmToken(token)],
  FunctionCallResponse(:final name, :final args) => [
    LlmToolCall(name: name, arguments: {...args}),
  ],
  ParallelFunctionCallResponse(:final calls) => [
    for (final call in calls)
      LlmToolCall(name: call.name, arguments: {...call.args}),
  ],
  // Thinking traces are dropped: this app never asks for thinking mode, the filter
  // is a safety net for bundles that emit `<think>` anyway, and a reasoning trace
  // is not something to render to a technician or to snapshot in a golden file.
  ThinkingResponse() => const [],
};
