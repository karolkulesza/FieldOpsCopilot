/// Runtime configuration for the on-device inference engine.
///
/// Deliberately expressed in this app's own vocabulary rather than
/// `flutter_gemma`'s: `ModelType`, `ModelFileType` and `PreferredBackend` are
/// plugin types, and the repo's hard rule is that every on-device capability sits
/// behind a Dart interface. Keeping the plugin's enums out of the config means the
/// only file that imports `flutter_gemma` is the runtime that actually calls it —
/// so swapping the runtime (or the model family) never touches a caller.
library;

/// Accelerator this build asks the runtime to use.
enum InferenceBackend {
  /// Let the engine choose, including its own fallback chain.
  ///
  /// The LiteRT-LM engine tries the accelerator first and falls back on its own;
  /// [InferenceConfig.backend] is a *preference*, and the backend that was really
  /// initialised comes back in [LoadedRuntime.backend]. Never assume the request
  /// was honoured — on an iOS simulator, for instance, there is no Metal GPU and
  /// the engine lands on CPU.
  auto,
  cpu,
  gpu,

  /// Qualcomm / MediaTek / Tensor on Android, Intel on Windows. Never iOS.
  npu,
}

/// Which prompt/tool-calling dialect the loaded weights speak.
///
/// This is not cosmetic: it decides *how tool calls reach us at all*.
///
/// * [gemma4] — the LiteRT-LM SDK renders the tool declarations into native
///   `<|tool>declaration:…<tool|>` tokens from the `tools_json` handed to the
///   conversation, and the model answers with native tool-call tokens that the
///   plugin surfaces as structured calls. No prompt engineering involved.
/// * [gemma3] — no native function-call tokens. The plugin injects a textual tool
///   declaration into the prompt and parses JSON back out of the generated text.
///
/// Both arrive at this app as the same structured `LlmToolCall`, which is the
/// whole point of the [LlmEngine] seam: the low-RAM fallback the sprint plan keeps
/// in reserve changes the mechanism, not the interface.
enum GemmaModelFamily {
  /// Gemma 4 E2B/E4B — the primary target, native function calling.
  gemma4,

  /// Gemma 3 1B — the low-RAM alternative, tool calls via prompt + JSON parse.
  gemma3,
}

/// Everything the inference worker needs to load a model and run a turn.
class InferenceConfig {
  const InferenceConfig({
    required this.modelPath,
    this.family = GemmaModelFamily.gemma4,
    this.backend = InferenceBackend.auto,
    this.contextTokens = defaultContextTokens,
    this.maxOutputTokens = 512,
    this.topK = 1,
    this.temperature = 0.8,
    this.randomSeed = 1,
  });

  /// Absolute path to the `.litertlm` weights.
  ///
  /// Always a file Task 1.7 has already downloaded, hashed against the pinned
  /// SHA-256 and installed by atomic rename. This task never fetches weights: the
  /// engine loading unverified bytes would make "the model is ready" a claim about
  /// a file that merely exists.
  final String modelPath;

  final GemmaModelFamily family;
  final InferenceBackend backend;

  /// Size of the KV cache in tokens — the **whole context window**, input plus
  /// output, not the reply length.
  ///
  /// `.litertlm` bundles bake a `kv_cache_max_len` of 1024 and the engine clamps
  /// anything smaller up to it, because a smaller window fails native tensor
  /// allocation at generation time. So 1024 is a floor, not a target: this app's
  /// prompts carry a whole manual procedure plus a tool result round-trip, and a
  /// window that overflows mid-turn costs a session rebuild. [maxOutputTokens] is
  /// what caps generation.
  final int contextTokens;

  /// Cap on tokens *generated* per turn. Bounds a runaway generation without
  /// touching the context window.
  final int maxOutputTokens;

  /// Sampling breadth. `1` is greedy decoding, and that is deliberate: the device
  /// acceptance tests assert on content, and a sampled model would make them flaky
  /// for reasons unrelated to the code under test.
  final int topK;

  /// Sampling temperature. **Inert while [topK] is 1** — greedy decoding takes the
  /// argmax and never consults it. Kept because raising [topK] is a one-line demo
  /// change, and a temperature that silently did nothing *after* that change would
  /// be worse than one that documents when it starts mattering.
  final double temperature;

  final int randomSeed;

  /// Context window this app asks for.
  ///
  /// Chosen over the plugin's 1024 default because the grounded prompt is not
  /// small: the E-102 manual entry alone is ~200 tokens of procedure, and the agent
  /// loop (Task 1.9) adds a tool declaration, a tool result and a second model turn
  /// on top of it. Costs a few MB of extra KV cache, which is cheap next to a
  /// mid-turn context overflow.
  static const int defaultContextTokens = 2048;

  InferenceConfig copyWith({
    String? modelPath,
    GemmaModelFamily? family,
    InferenceBackend? backend,
    int? contextTokens,
    int? maxOutputTokens,
    int? topK,
    double? temperature,
    int? randomSeed,
  }) => InferenceConfig(
    modelPath: modelPath ?? this.modelPath,
    family: family ?? this.family,
    backend: backend ?? this.backend,
    contextTokens: contextTokens ?? this.contextTokens,
    maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
    topK: topK ?? this.topK,
    temperature: temperature ?? this.temperature,
    randomSeed: randomSeed ?? this.randomSeed,
  );

  Map<String, Object?> toWire() => {
    'modelPath': modelPath,
    'family': family.name,
    'backend': backend.name,
    'contextTokens': contextTokens,
    'maxOutputTokens': maxOutputTokens,
    'topK': topK,
    'temperature': temperature,
    'randomSeed': randomSeed,
  };

  /// Rebuilds a config from [wire].
  ///
  /// Throws [FormatException] on anything it cannot read, rather than falling back
  /// to defaults: this decodes a message *this app* just encoded, so a mismatch is
  /// a protocol bug, and silently loading a model with the wrong context window
  /// would surface much later as an unexplained allocation failure.
  static InferenceConfig fromWire(Map<String, Object?> wire) {
    final modelPath = wire['modelPath'];
    if (modelPath is! String || modelPath.isEmpty) {
      throw const FormatException('inference config: missing modelPath');
    }
    return InferenceConfig(
      modelPath: modelPath,
      family: _enumByName(GemmaModelFamily.values, wire['family'], 'family'),
      backend: _enumByName(InferenceBackend.values, wire['backend'], 'backend'),
      contextTokens: _int(wire['contextTokens'], 'contextTokens'),
      maxOutputTokens: _int(wire['maxOutputTokens'], 'maxOutputTokens'),
      topK: _int(wire['topK'], 'topK'),
      temperature: _double(wire['temperature'], 'temperature'),
      randomSeed: _int(wire['randomSeed'], 'randomSeed'),
    );
  }

  @override
  String toString() =>
      'InferenceConfig(${family.name}, ${backend.name}, '
      'context: $contextTokens, maxOutput: $maxOutputTokens)';

  static T _enumByName<T extends Enum>(
    List<T> values,
    Object? raw,
    String field,
  ) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    throw FormatException('inference config: unknown $field "$raw"');
  }

  static int _int(Object? raw, String field) {
    if (raw is int) return raw;
    throw FormatException('inference config: $field is not an int ($raw)');
  }

  static double _double(Object? raw, String field) {
    if (raw is double) return raw;
    if (raw is int) return raw.toDouble();
    throw FormatException('inference config: $field is not a number ($raw)');
  }
}

/// What a completed load reports back about the runtime it actually got.
///
/// The requested backend and the live one are different facts — the engine falls
/// back silently — so the app records what it was given rather than what it asked
/// for. [loadMillis] is the number the sprint plan wants measured on the demo
/// device: the spike's whole question is whether a 2.6GB model loads and runs
/// acceptably on real hardware.
class LoadedRuntime {
  const LoadedRuntime({
    required this.backend,
    required this.loadMillis,
    required this.contextTokens,
  });

  /// Backend name as reported by the runtime, or `'unknown'` when it does not say.
  final String backend;

  /// Wall-clock milliseconds from "load requested" to "engine ready".
  final int loadMillis;

  /// Context window the engine settled on, after its own clamping.
  final int contextTokens;

  Map<String, Object?> toWire() => {
    'backend': backend,
    'loadMillis': loadMillis,
    'contextTokens': contextTokens,
  };

  /// Reads a load report off the wire.
  ///
  /// Unlike [InferenceConfig.fromWire] this tolerates a missing backend name,
  /// because "the runtime did not say" is a real answer the FFI layer gives — it
  /// only reports a backend once it has one. A missing *measurement* is not
  /// tolerated: a load time of 0 would read as an instant load of a 2.6GB model,
  /// which is the one number this task exists to establish.
  static LoadedRuntime fromWire(Map<String, Object?> wire) => LoadedRuntime(
    backend: wire['backend'] as String? ?? unknownBackend,
    loadMillis: InferenceConfig._int(wire['loadMillis'], 'loadMillis'),
    contextTokens: InferenceConfig._int(wire['contextTokens'], 'contextTokens'),
  );

  /// Reported when the runtime does not name the backend it initialised.
  static const String unknownBackend = 'unknown';

  @override
  String toString() =>
      'LoadedRuntime($backend, ${loadMillis}ms, context: $contextTokens)';
}
