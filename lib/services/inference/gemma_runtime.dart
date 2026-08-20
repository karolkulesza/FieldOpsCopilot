/// The only file in this app that talks to `flutter_gemma`.
///
/// Everything above it speaks `LlmEngine` / `LlmEvent` and this file is
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
/// 2. **`supportsFunctionCalls` must be set whenever tools are passed**, and what it
///    gates differs by family — so the same omission fails in two different ways:
///    * **Gemma 4:** the declaration reaches the model regardless (it is gated only
///      on model type and a non-empty tool list), but `InferenceChat` only *reads
///      back* the structured calls when the flag is true. Miss it and the model
///      dutifully emits a tool call that is parsed and then discarded — which looks
///      exactly like a model that will not call tools.
///    * **Gemma 3 (`gemmaIt`):** the flag gates the *declaration* as well. Miss it
///      and the tools are never mentioned to the model at all; the plugin logs
///      "Tools will be ignored" and carries on.
///    This app passes `supportsFunctionCalls: tools.isNotEmpty`, so both are avoided
///    — but the distinction is what a reader needs when flipping to the fallback.
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
  /// would be the same per-isolate-versus-process confusion that once bit the
  /// provisioner's staging nonce. An instance field says what it means — this runtime initialised
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
      // grounded prompt carries customer-site text, and the design is
      // explicit that it must not leak off-device — a log line is a leak.
      FlutterGemma.logLevel = GemmaLogLevel.info;
      await FlutterGemma.initialize(inferenceEngines: const [LiteRtLmEngine()]);
      _pluginInitialized = true;
    }

    // `fromFile` *registers* the path — it copies nothing. That matters: the
    // artifact is 2.6GB and the provisioner already placed it in no-backup application
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
      // A **Dart-side** value, not a native report. `LiteRtLmEngine` computes
      // `max(requested, 1024)` before native initialisation and hands that same
      // number to the model object; nothing in either package reads what the native
      // KV-cache actually allocated, and the package says so explicitly ("No native
      // API reports the model's minimum, so we clamp up to the largest known
      // minimum"). So this witnesses the window this app *asked for*, after the
      // engine's floor — useful for spotting a request that was silently raised, and
      // not evidence about native allocation.
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
    // Note there is no schema validation here. It happens in `GemmaLlmEngine.generate`,
    // at the app-facing entry, so a malformed tool throws at the call site that
    // registered it rather than as an async failure surfacing out of an isolate — and
    // so the rule can be bound by a host test, which a check in this class could not
    // be (it needs a loaded model to reach).

    // One chat per turn. Two reasons, both load-bearing:
    //   * a chat's tools are baked into its session at creation (see the class
    //     doc), so a per-turn tool set needs a per-turn session; and
    //   * `LlmEngine.generate` is a *stateless* turn — the fake behaves that way and
    //     the golden suite depends on it — so history from turn N must not leak into
    //     N+1. Multi-turn tool round-trips belong to the agent loop, which extends
    //     the interface rather than quietly inheriting a chat's accumulated history.
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
      // `modelType` is deliberately not passed: on this app's path it defaults to
      // the type the loaded spec carries, and naming it here would let a config
      // drift from the weights that are actually resident. Note that is
      // `FfiInferenceModel`'s override doing it (`modelType ?? this.modelType`),
      // not the plugin's API contract — the base `createChat` defaults to
      // `ModelType.gemmaIt` and does not forward `tools` to the session at all. The
      // FFI engine is the only override in either package, and it is the one this
      // app uses; a different engine would need this argument passed explicitly.
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
    // A stop for a turn that already finished is normal — the stop request and the
    // last token race each other — and two separate things make it harmless. A null
    // `_chat` is a no-op because of `?.`, nothing more. A *non-null* chat whose
    // generation already ended is safe because the plugin's cancel is idempotent,
    // including against a conversation that has already been freed.
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
    // be the JSON-Schema object the plugin wants (see `engines/tool_schema.dart`), and this
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
