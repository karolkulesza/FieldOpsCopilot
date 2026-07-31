import 'dart:async';
import 'dart:io';

import 'package:field_ops_copilot/engines/impl/gemma_llm_engine.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/engines/tool_schema.dart';
import 'package:field_ops_copilot/services/inference/inference_config.dart';
import 'package:field_ops_copilot/services/inference/providers.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_provisioner.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Task 1.8's acceptance criteria — TC-LLM-LOAD-01, TC-LLM-GEN-01 and
/// TC-LLM-TOOLCALL-01 — on a real device, against real weights.
///
/// ```sh
/// flutter test integration_test/llm_inference_test.dart -d <device id> \
///   --dart-define=FIELDOPS_MODEL_URI=<resolve URL for the file you licensed> \
///   --dart-define=FIELDOPS_MODEL_SHA256=<its sha256>
/// ```
///
/// The defines are what make the installed artifact *verifiable*: this suite refuses
/// to load weights whose digest nothing has checked. If the model is not installed and
/// verified, every test **skips with the reason** rather than failing — a checkout has
/// no 2.6GB artifact and CI must not fetch one, which is also why this lives in
/// `integration_test/`.
///
/// Add `--dart-define=FIELDOPS_TEST_PROVISION=true` to have the suite download the
/// weights itself first. That is needed more often than it looks: `flutter test`
/// re-installs the app for each suite and wipes its data container, so weights
/// downloaded by `model_provisioning_test.dart` are already gone by the time this file
/// runs. Side-loading, or a device where the app is installed once and driven
/// repeatedly, avoids it.
///
/// Assertions are fuzzy on purpose (the plan's word). A model's exact wording is not
/// a contract, so what is asserted is behaviour: it loads, it streams, it terminates,
/// and under grounding with a registered tool it emits a *structured* call naming the
/// right tool and SKU. Decoding is greedy (`topK: 1`), so the run is reproducible
/// without the assertions having to pin tokens.
///
/// The run also prints the measurements Task 1.8 is expected to produce — load time,
/// time to first token, tokens per second, resident footprint, and how long the UI
/// isolate was ever blocked. Those are recorded in the sprint plan; they are printed
/// rather than asserted because a threshold that fails on a cold cache or a warm
/// device would be a flaky test pretending to be an NFR.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final descriptor = ModelCatalog.active;

  /// The engine, loaded once and shared: a load is minutes of wall clock and
  /// gigabytes of RAM, and re-doing it per test would prove nothing extra.
  GemmaLlmEngine? engine;
  late String skipReason;
  var loadProbe = _IsolateBlockingProbe.empty();

  setUpAll(() async {
    // Read first, before anything expensive. Two reasons, and the second is the one that
    // matters: a mistyped backend name should fail in the first second rather than after an
    // optional 2.59GB download, and evaluating it here means it is exercised on **every**
    // invocation — including runs that skip for want of weights, which is the only coverage
    // available when no device is attached.
    final backend = _configuredBackend;

    final storage = await ModelStorage.openDefault();
    final provisioner = ModelProvisioner(storage: storage);
    addTearDown(provisioner.dispose);

    final issue = descriptor.configurationIssue;
    var status = await provisioner.statusOf(descriptor);

    // Fresh app container? Fetch the weights, but only when explicitly asked to.
    //
    // `flutter test integration_test/…` **re-installs the app for every suite**, and
    // that wipes its data container — so the artifact the provisioning suite just
    // downloaded is gone by the time this one starts. On a device that is worked
    // around by side-loading or by a manual provisioning run; on a simulator or a
    // freshly re-installed app there is nothing to work around it with, hence this
    // switch.
    //
    // It is opt-in rather than automatic because the default matters: a 2.6GB
    // transfer inside an inference suite turns a network failure into what looks like
    // an inference failure, and this file's whole job is to say something trustworthy
    // about the model.
    if (issue == null &&
        status != ModelInstallStatus.ready &&
        _provisionIfMissing) {
      debugPrint('[TC-LLM] provisioning weights first (opt-in)');
      var lastPercent = -1;
      final result = await provisioner.provision(
        descriptor,
        onProgress: (progress) {
          final fraction = progress.fraction;
          if (fraction == null) return;
          final percent = (fraction * 100).floor();
          if (percent > lastPercent) {
            lastPercent = percent;
            if (percent % 10 == 0) {
              debugPrint('[TC-LLM] ${progress.phase.name}: $percent%');
            }
          }
        },
      );
      debugPrint('[TC-LLM] provisioning result: ${result.runtimeType}');
      status = await provisioner.statusOf(descriptor);
    }

    skipReason = switch ((issue, status)) {
      (final issue?, _) =>
        'model source not configured (${issue.name}) — pass '
            'FIELDOPS_MODEL_URI and FIELDOPS_MODEL_SHA256. '
            'License: ${descriptor.licensePage}',
      // Not fetched unless asked — see the opt-in above.
      (_, ModelInstallStatus.absent) =>
        'weights are not installed — pass '
            '--dart-define=$_provisionFlag=true to fetch them as part of this '
            'run, or side-load ${descriptor.fileName} into '
            '<app support>/models. Note that a separate run of '
            'model_provisioning_test.dart does *not* help: each suite '
            're-installs the app and wipes its data container.',
      // Present but unhashed against the current pin. Loading anyway is the one
      // thing Task 1.7 exists to prevent.
      (_, ModelInstallStatus.unverified) =>
        'weights are present but unverified against the pinned SHA-256 — run '
            'provisioning to verify them before loading',
      (_, ModelInstallStatus.ready) => '',
    };
    if (skipReason.isNotEmpty) return;

    final path = storage.installedFile(descriptor).path;
    debugPrint('[TC-LLM] model: $path');
    debugPrint(
      '[TC-LLM] size: ${await storage.installedFile(descriptor).length()} bytes',
    );
    debugPrint(
      '[TC-LLM] rss before load: ${_formatRss(ProcessInfo.currentRss)}',
    );

    final candidate = GemmaLlmEngine(
      config: InferenceConfig(
        modelPath: path,
        family: inferenceFamilyFor(descriptor.id),
        backend: backend,
      ),
    );
    // Measured across the load, because a 2.6GB memory-map is the single most
    // likely thing in this app to stall the UI isolate — and the claim that it does
    // not is the reason the engine sits behind an isolate at all.
    loadProbe = await _IsolateBlockingProbe.measure(candidate.initialize);
    engine = candidate;
  });

  tearDownAll(() async {
    await engine?.dispose();
  });

  /// Returns the shared engine, or skips the calling test with the reason.
  GemmaLlmEngine? requireEngine() {
    if (skipReason.isNotEmpty) {
      markTestSkipped(skipReason);
      return null;
    }
    return engine;
  }

  testWidgets(
    'TC-LLM-LOAD-01: the engine loads the provisioned weights and reports ready',
    (tester) async {
      final engine = requireEngine();
      if (engine == null) return;

      expect(engine.isReady, isTrue);

      final runtime = engine.runtime!;
      debugPrint(
        '[TC-LLM-LOAD-01] requested=${engine.config.backend.name} '
        'backend=${runtime.backend} load=${runtime.loadMillis}ms '
        'context=${runtime.contextTokens} tokens',
      );
      debugPrint(
        '[TC-LLM-LOAD-01] rss after load: '
        '${_formatRss(ProcessInfo.currentRss)}',
      );
      debugPrint('[TC-LLM-LOAD-01] $loadProbe');

      // The load really happened rather than being short-circuited: nothing maps a
      // multi-gigabyte model in under a millisecond.
      expect(runtime.loadMillis, greaterThan(0));

      // What this can and cannot witness, stated exactly, because the first version
      // of this assertion was a tautology dressed as a measurement:
      // `LoadedRuntime.contextTokens` is `max(requested, 1024)` computed in Dart
      // before the engine touches native code, so `>= 2048` could not fail on any
      // device, with any model, or with no model at all. Nothing in either package
      // reports the KV-cache the native runtime really allocated.
      //
      // Equality against what was requested *is* falsifiable: it fails if the value
      // is mangled crossing the config → wire → plugin path, and it fails if the
      // engine's floor silently raises a request — which is what would happen to
      // anyone who lowered `contextTokens` below 1024 expecting a shorter reply.
      expect(
        runtime.contextTokens,
        engine.config.contextTokens,
        reason:
            'the requested context window must survive the isolate hop unchanged '
            'and must not have been raised by the engine floor',
      );
      expect(
        engine.config.contextTokens,
        greaterThanOrEqualTo(InferenceConfig.litertlmContextFloor),
        reason: 'below the .litertlm floor the engine would raise it silently',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'TC-LLM-GEN-01: a prompt streams tokens and terminates cleanly',
    (tester) async {
      final engine = requireEngine();
      if (engine == null) return;

      final tokens = <String>[];
      var done = false;
      final stopwatch = Stopwatch()..start();
      int? firstTokenMillis;

      final probe = await _IsolateBlockingProbe.measure(() async {
        await for (final event in engine.generate(prompt: 'Say OK')) {
          switch (event) {
            case LlmToken(:final text):
              firstTokenMillis ??= stopwatch.elapsedMilliseconds;
              tokens.add(text);
            case LlmToolCall():
              fail('a prompt with no registered tools must not yield a call');
            case LlmDone():
              done = true;
          }
        }
      });
      stopwatch.stop();

      final tokensPerSecond =
          tokens.length /
          (stopwatch.elapsedMilliseconds / 1000).clamp(0.001, double.infinity);
      debugPrint(
        '[TC-LLM-GEN-01] ${tokens.length} tokens in '
        '${stopwatch.elapsedMilliseconds}ms — ttft=${firstTokenMillis}ms, '
        '${tokensPerSecond.toStringAsFixed(1)} tok/s',
      );
      debugPrint('[TC-LLM-GEN-01] answer: ${tokens.join()}');
      debugPrint('[TC-LLM-GEN-01] $probe');

      expect(tokens, isNotEmpty, reason: 'the model produced no tokens at all');
      // "Terminates cleanly" is the half of this criterion that a consumer depends
      // on: a stream that yields tokens and then never completes hangs the agent
      // loop, and no assertion on the text would notice.
      expect(done, isTrue, reason: 'the stream never delivered LlmDone');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'TC-LLM-TOOLCALL-01: a grounded prompt yields a native tool call for the SKU',
    (tester) async {
      final engine = requireEngine();
      if (engine == null) return;

      final calls = <LlmToolCall>[];
      final prose = StringBuffer();
      var done = false;
      final stopwatch = Stopwatch()..start();

      await for (final event in engine.generate(
        prompt: _groundedE102Prompt,
        tools: [_inventoryTool],
      )) {
        switch (event) {
          case LlmToken(:final text):
            prose.write(text);
          case LlmToolCall call:
            calls.add(call);
          case LlmDone():
            // Recorded, not `break`ed: a bare `break` here leaves the `switch`, not
            // the `await for`, so it would assert nothing. The turn that carries a
            // tool call has to terminate as cleanly as a plain one — the agent loop
            // waits on exactly this event before executing the tool.
            done = true;
        }
      }
      stopwatch.stop();

      debugPrint(
        '[TC-LLM-TOOLCALL-01] ${stopwatch.elapsedMilliseconds}ms, '
        '${calls.length} tool call(s)',
      );
      for (final call in calls) {
        debugPrint('[TC-LLM-TOOLCALL-01] call: ${call.name} ${call.arguments}');
      }
      debugPrint('[TC-LLM-TOOLCALL-01] prose: $prose');

      // Fuzzy as the plan requires: the tool *name* and the *SKU* are the contract
      // — the agent loop routes on the first and queries the database with the
      // second. Everything else the model says is prose.
      expect(
        calls,
        isNotEmpty,
        reason:
            'no structured tool call arrived. If the model answered in prose '
            'instead, the degraded path is Task 1.6\'s guard — but a Gemma 4 '
            'bundle with tools_json should emit a native call here.',
      );
      final call = calls.firstWhere(
        (call) => call.name == 'get_local_parts_inventory',
        orElse: () => fail(
          'expected a get_local_parts_inventory call, got '
          '${calls.map((call) => call.name).toList()}',
        ),
      );
      expect(
        '${call.arguments['sku']}'.toUpperCase(),
        contains('BRK-990-XP'),
        reason: 'the call must carry the SKU the manual entry names',
      );
      expect(
        done,
        isTrue,
        reason: 'a turn carrying a tool call must still terminate with LlmDone',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'a second turn does not inherit the first turn\'s history',
    (tester) async {
      // Not an AC, but the property Task 1.9 will build on and the one most likely to
      // break silently: `LlmEngine.generate` is contracted as a *stateless* turn, and
      // the fake behaves that way.
      //
      // The question matters more than the assertion. An earlier version asked for
      // "the colour of a clear sky at noon" and asserted the answer did not mention a
      // SKU — which a model carrying the entire E-102 conversation would also pass,
      // since it would still answer "Blue". This asks something **only the previous
      // turn's history could answer**: with a leaked conversation the model has the
      // fault code and will name it; with a fresh chat it cannot know it.
      final engine = requireEngine();
      if (engine == null) return;

      final tokens = <String>[];
      await for (final event in engine.generate(
        prompt:
            'Which fault code did I ask you about in my previous message? '
            'If there was no previous message, reply with exactly: NONE',
      )) {
        if (event is LlmToken) tokens.add(event.text);
      }

      final answer = tokens.join().trim();
      debugPrint('[TC-LLM-STATELESS] answer: $answer');
      expect(answer, isNotEmpty);
      // The leak detector: E-102 is knowable only from the turn before this one.
      expect(
        answer.toUpperCase(),
        isNot(contains('102')),
        reason:
            'the model named a fault code it could only have from the previous '
            'turn — history leaked across generate() calls',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

/// Backend override, for narrowing where the load-time UI stall comes from.
///
/// The device run showed the UI isolate blocked for 1445-1728ms during `initialize()`, and
/// one of the three candidate causes is first-load Metal pipeline compilation. Forcing
/// `cpu` on the device is the cheapest discriminator available: if the stall persists
/// without Metal, that candidate is out. Defaults to `auto` (engine's choice), which is
/// what the acceptance runs used.
///
/// **Exercised once, on the device, and it produced the answer it was built for.** With
/// `cpu` the run logged `requested=cpu backend=cpu` — so the override was honoured rather
/// than silently falling back, which is why `TC-LLM-LOAD-01` logs requested-versus-actual at
/// all — and the UI-isolate stall was **2197ms, worse than the 1445-1728ms seen on Metal**.
/// First-load Metal pipeline compilation is therefore **not** the cause. `flutter test` still
/// does not run this directory, so `flutter analyze` plus that single device run is the whole
/// of its verification.
const String _backendFlag = 'FIELDOPS_TEST_BACKEND';

const String _backendName = String.fromEnvironment(
  _backendFlag,
  defaultValue: 'auto',
);

InferenceBackend get _configuredBackend => InferenceBackend.values.firstWhere(
  (backend) => backend.name == _backendName,
  orElse: () => throw ArgumentError.value(
    _backendName,
    _backendFlag,
    'expected one of ${InferenceBackend.values.map((b) => b.name).join(', ')}',
  ),
);

/// Build flag that lets this suite fetch the weights when the container is empty.
const String _provisionFlag = 'FIELDOPS_TEST_PROVISION';

const bool _provisionIfMissing = bool.fromEnvironment(_provisionFlag);

/// The tool Task 1.5's registry will own, declared here in the shape the runtime
/// requires so this task can prove native function calling before 1.5 exists.
final _inventoryTool = ToolDefinition(
  name: 'get_local_parts_inventory',
  description:
      'Check the offline warehouse database for stock count and shelf '
      'location of a spare part, by SKU.',
  parameters: objectSchema(
    properties: {
      'sku': {
        'type': 'string',
        'description': 'The part number, for example BRK-990-XP.',
      },
    },
    required: ['sku'],
  ),
);

/// Stands in for Task 1.4's prompt compiler.
///
/// Copied in the shape §5.2 of the spec describes — a `[MANUAL DOCUMENT]` block from
/// the E-102 seed entry, then the technician's inquiry — so that when 1.4 lands, this
/// test's input is a compiler output rather than a rewrite.
const _groundedE102Prompt = '''
You are an offline Field Service Assistant for Apex-9 smart elevators.
Answer using ONLY the verified technical manual document below.
If a replacement part is required, you MUST call the
get_local_parts_inventory tool to check warehouse stock before advising the
technician.

[MANUAL DOCUMENT]
Title: Traction Brake Pad Wear & Vibration (Code: E-102)
Section: Brake Systems
Symptoms: High-pitched squealing during deceleration, cabin vibration at
terminal landings, fault code E-102 displayed on machine room controller.
Procedure: 1. Isolate the main elevator power bus. 2. Lockout/tagout machine
room breaker 4A. 3. Remove the magnetic brake cowl using a Torx T20 driver.
4. Inspect brake pad wear indicators. If thickness is less than 2.0mm, replace
the assemblies. 5. Adjust caliper clearance to exactly 0.5mm.
Required tools: Torx T20, Digital Caliper, Lockout Tagout Kit
Required parts: BRK-990-XP

[USER INQUIRY]
The elevator cabin is vibrating badly and I'm seeing error E-102 in the
machine room. What do I do, and do we have the part?
''';

/// Measures how long the **UI isolate** was ever prevented from running while some
/// other work was in flight.
///
/// This is the evidence for the isolate boundary rather than an argument for it. A
/// periodic timer on this isolate should tick every [_tick]; if inference were
/// running here, the model load would show up as a gap of seconds and every frame in
/// it would be dropped. Reported as the worst gap observed, which is the number that
/// matters — an average would hide exactly the stall a user notices.
class _IsolateBlockingProbe {
  _IsolateBlockingProbe(this.worstGap, this.ticks, this.elapsed);

  factory _IsolateBlockingProbe.empty() =>
      _IsolateBlockingProbe(Duration.zero, 0, Duration.zero);

  static const Duration _tick = Duration(milliseconds: 16);

  final Duration worstGap;
  final int ticks;
  final Duration elapsed;

  /// Runs [body], ticking a timer on this isolate throughout.
  static Future<_IsolateBlockingProbe> measure(
    Future<void> Function() body,
  ) async {
    final total = Stopwatch()..start();
    final sinceLastTick = Stopwatch()..start();
    var worstGap = Duration.zero;
    var ticks = 0;

    final timer = Timer.periodic(_tick, (_) {
      ticks++;
      final gap = sinceLastTick.elapsed;
      if (gap > worstGap) worstGap = gap;
      sinceLastTick
        ..reset()
        ..start();
    });
    try {
      await body();
    } finally {
      timer.cancel();
      total.stop();
    }
    return _IsolateBlockingProbe(worstGap, ticks, total.elapsed);
  }

  @override
  String toString() =>
      'ui isolate: $ticks ticks over ${elapsed.inMilliseconds}ms, '
      'worst gap ${worstGap.inMilliseconds}ms';
}

String _formatRss(int bytes) => bytes <= 0
    // `currentRss` is not implemented on every platform, and reporting 0 MB as a
    // measurement would be worse than admitting it is unavailable.
    ? 'unavailable'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
