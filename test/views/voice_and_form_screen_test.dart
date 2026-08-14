import 'dart:async';
import 'dart:typed_data';

import 'package:field_ops_copilot/app.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/engines/stt_engine.dart';
import 'package:field_ops_copilot/models/form_state_model.dart';
import 'package:field_ops_copilot/services/ai/tools/record_work_order_fields_tool.dart';
import 'package:field_ops_copilot/services/audio/mic_capture.dart';
import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:field_ops_copilot/services/audio/providers.dart';
import 'package:field_ops_copilot/services/database/providers.dart';
import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/inference/engine_warmup_controller.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:field_ops_copilot/services/models/providers.dart';
import 'package:field_ops_copilot/viewmodels/dictation_viewmodel.dart';
import 'package:field_ops_copilot/viewmodels/work_order_form_viewmodel.dart';
import 'package:field_ops_copilot/views/components/clarification_dialog.dart';
import 'package:field_ops_copilot/views/components/work_order_form_panel.dart';
import 'package:field_ops_copilot/views/diagnose_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Task 2.3 on the screen: the microphone button, the transcript reaching the
/// inquiry field, and the work order filling in.
///
/// Separate from `diagnose_screen_test.dart` deliberately — that file owns Task
/// 1.11's properties and its harness is built around injecting a `FieldJobState`.
/// What is asserted here is what 2.3 added, over the *real* dictation and form
/// viewmodels with only the two device seams scripted. The engine and the
/// microphone are the only doubles: everything between the transcript and the
/// characters in the text field is production code.
void main() {
  late _ScriptedAudioInput input;
  late _ScriptedSttEngine engine;

  setUp(() {
    input = _ScriptedAudioInput();
    engine = _ScriptedSttEngine();
  });

  /// Pumps the real app with the two device seams scripted.
  ///
  /// The surface is the demo device's shape rather than the 800x600 default: the
  /// screen now carries an answer panel *and* a work order, and a viewport that
  /// cannot show both makes every assertion about the second one an assertion
  /// about scrolling. The iPad Air M4 this is demoed from is 1180x820 logical.
  Future<ProviderContainer> pumpScreen(
    WidgetTester tester, {
    SttEngine? Function()? stt,
  }) async {
    tester.view.physicalSize = const Size(1180, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        modelInstallStatusProvider.overrideWith(
          (ref, modelId) async => ModelInstallStatus.ready,
        ),
        seedOutcomeProvider.overrideWith(
          (ref) async => const SeedSkipped(storedRevision: 1, assetRevision: 1),
        ),
        engineWarmupControllerProvider.overrideWith(
          () => _StubWarmup(const EngineReady(_InertEngine())),
        ),
        micCaptureProvider.overrideWith((ref) {
          // **`stallTimeout: null`, and it is the test that is wrong without
          // it rather than the production default.** The watchdog is a real
          // `Timer(5s)` armed for the whole of a capture, and `flutter_test`
          // fails any test that ends with one pending — which Task 2.1's own
          // source predicted in as many words ("a widget is where Task 2.3 puts
          // this"). Every test here ends mid-capture or just after one, so the
          // alternative is a tear-down that waits out five seconds of fake clock
          // in twelve tests to observe a timer that never fires. The watchdog's
          // behaviour is bound by `mic_capture_test.dart`, at millisecond scale,
          // where it is the subject rather than a fixture.
          final capture = MicCapture(input: input, stallTimeout: null);
          ref.onDispose(capture.dispose);
          return capture;
        }),
        dictationEngineProvider.overrideWith(
          (ref) async => stt == null ? engine : stt(),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FieldOpsApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  String inquiryText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(DiagnoseKeys.inquiryField))
      .controller!
      .text;

  /// Taps the microphone and lets the whole start/stop chain finish.
  ///
  /// **`runAsync`, not `pump(Duration)`, and the difference is the whole reason
  /// this helper exists.** A widget test's clock and timers are faked, and
  /// `MicCaptureSession.stop` completes only when the *stream* the plugin owns
  /// delivers its `done` — real asynchronous work that the fake-async zone never
  /// gets a slice for, however far the fake clock is advanced. Measured with a
  /// matched control before this was written: eight `pump(100ms)`s left
  /// `session.stop()` unresolved and `frames` still open, and eight
  /// `runAsync(20ms)`s resolved both. Advancing the clock is not the same as
  /// giving the event loop time.
  ///
  /// This is `diagnose_screen_test.dart`'s `settleRealAsync` under another name;
  /// it is duplicated rather than shared because these two files have no common
  /// harness and importing one test's private helper into another is worse.
  /// Real event-loop time, then frames. See [tapMic] for why `pump` alone is not
  /// enough — and note that a *typed* edit now also closes a capture (R0-F1), so
  /// this is needed after `enterText` during dictation for the same reason.
  Future<void> settleAsync(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> tapMic(WidgetTester tester) async {
    await tester.tap(find.byKey(DiagnoseKeys.dictateButton));
    await settleAsync(tester);
  }

  group('the microphone button', () {
    testWidgets('is on screen and idle says nothing', (tester) async {
      await pumpScreen(tester);

      expect(find.byKey(DiagnoseKeys.dictateButton), findsOneWidget);
      expect(
        find.byKey(DiagnoseKeys.dictationStatus),
        findsNothing,
        reason: 'an idle microphone has nothing to say',
      );
    });

    testWidgets('tapping it opens the microphone and says so', (tester) async {
      final container = await pumpScreen(tester);

      await tapMic(tester);

      expect(input.startStreamCalls, 1);
      expect(
        container.read(dictationControllerProvider).phase,
        DictationPhase.listening,
      );
      expect(find.byKey(DiagnoseKeys.dictationStatus), findsOneWidget);
      expect(find.textContaining('Listening'), findsOneWidget);
    });

    testWidgets('tapping it again stops', (tester) async {
      final container = await pumpScreen(tester);
      await tapMic(tester);

      await tapMic(tester);

      expect(
        container.read(dictationControllerProvider).phase,
        DictationPhase.idle,
      );
      expect(find.textContaining('Listening'), findsNothing);
    });

    // The `null`-not-a-fake rule reaching the screen: on a device with no verified
    // speech weights the button still works, and what it produces is a sentence
    // rather than a scripted transcript.
    testWidgets('with no weights it reports rather than transcribes', (
      tester,
    ) async {
      await pumpScreen(tester, stt: () => null);

      await tapMic(tester);

      expect(find.textContaining('No verified speech model'), findsOneWidget);
      expect(input.startStreamCalls, 0);
      expect(inquiryText(tester), '');
    });

    testWidgets('a denied permission reports rather than transcribes', (
      tester,
    ) async {
      input.permission = false;
      await pumpScreen(tester);

      await tapMic(tester);

      expect(find.textContaining('Settings'), findsOneWidget);
      expect(inquiryText(tester), '');
    });

    // The screen's own no-animation rule, extended to what 2.3 added — Task 1.8
    // measured the UI isolate dropping frames while tokens stream, and the
    // recogniser's own state updates land on that isolate too.
    testWidgets('nothing on the dictation path animates', (tester) async {
      await pumpScreen(tester);
      await tapMic(tester);

      expect(
        find.byWidgetPredicate((widget) => widget is ProgressIndicator),
        findsNothing,
      );
    });
  });

  group('the transcript reaches the inquiry field', () {
    testWidgets('a partial appears as it is heard', (tester) async {
      await pumpScreen(tester);
      await tapMic(tester);

      await engine.push(tester, const SttTranscript('THE CABIN IS VIBRATING'));

      expect(inquiryText(tester), 'THE CABIN IS VIBRATING');
    });

    testWidgets('two utterances build one line', (tester) async {
      await pumpScreen(tester);
      await tapMic(tester);

      await engine.push(
        tester,
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );
      await engine.push(
        tester,
        const SttTranscript(
          'THE FAULT CODE IS E 102',
          isFinal: true,
          segment: 1,
        ),
      );

      expect(
        inquiryText(tester),
        'THE CABIN IS VIBRATING THE FAULT CODE IS E 102',
      );
    });

    // The decision `_dictationBase` exists for: a technician who typed half the
    // inquiry and then reached for the microphone must not lose the half they
    // typed.
    testWidgets('dictation appends to what was typed', (tester) async {
      await pumpScreen(tester);
      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating',
      );
      await tester.pumpAndSettle();

      await tapMic(tester);
      await engine.push(
        tester,
        const SttTranscript('THE FAULT CODE IS E 102', isFinal: true),
      );

      expect(inquiryText(tester), 'cabin vibrating THE FAULT CODE IS E 102');
    });

    testWidgets('a second dictation appends to the first', (tester) async {
      await pumpScreen(tester);
      await tapMic(tester);
      await engine.push(
        tester,
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );
      await tapMic(tester);

      await tapMic(tester);
      await engine.push(tester, const SttTranscript('E 102', isFinal: true));

      expect(inquiryText(tester), 'THE CABIN IS VIBRATING E 102');
    });

    // **Review finding R0-F1.** The screen's own comment argues the field is not
    // read-only while dictating "because a technician who sees `FALK CODE` land
    // has to be able to fix it" — and until R0-F1 that was the one case that
    // failed: `_onDictation` rebuilds the whole line from `base + transcript` on
    // every state change, so the next partial wiped the correction. Two tests,
    // because the reviewer measured two ways to lose it.
    testWidgets('a mid-capture correction survives the next partial', (
      tester,
    ) async {
      final container = await pumpScreen(tester);
      await tapMic(tester);
      await engine.push(tester, const SttTranscript('FALK CODE E 102'));

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'FAULT CODE E 102',
      );
      await settleAsync(tester);
      // The edit stops the capture, which is what makes the words stop arriving
      // rather than the status line lying about a microphone nobody is mirroring.
      expect(
        container.read(dictationControllerProvider).isActive,
        isFalse,
        reason:
            'typing takes the field, and an unmirrored capture reads as broken',
      );

      // Whatever the recogniser says next cannot reach the field.
      await engine.push(tester, const SttTranscript('FALK CODE E 102 AGAIN'));

      expect(inquiryText(tester), 'FAULT CODE E 102');
    });

    testWidgets('a mid-capture correction survives the capture ending', (
      tester,
    ) async {
      // The second way the reviewer lost it: no further speech at all, just the
      // phase change at the end of the capture firing `_onDictation` once more.
      await pumpScreen(tester);
      await tapMic(tester);
      await engine.push(
        tester,
        const SttTranscript('FALK CODE E 102', isFinal: true),
      );

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'FAULT CODE E 102',
      );
      await tester.pumpAndSettle();

      expect(inquiryText(tester), 'FAULT CODE E 102');
    });

    testWidgets('a later dictation appends to the corrected text', (
      tester,
    ) async {
      // And the correction becomes the base of the next capture, so taking the
      // field is not the same as giving up on the microphone.
      await pumpScreen(tester);
      await tapMic(tester);
      await engine.push(tester, const SttTranscript('FALK CODE'));
      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'FAULT CODE',
      );
      await settleAsync(tester);

      await tapMic(tester);
      await engine.push(tester, const SttTranscript('E 102', isFinal: true));

      expect(inquiryText(tester), 'FAULT CODE E 102');
    });

    // Diagnose is disabled while dictating: the microphone is writing the inquiry
    // a run would be reading, and a prompt compiled from a sentence that is still
    // being spoken is a question nobody asked.
    testWidgets('Diagnose is inert while the microphone is open', (
      tester,
    ) async {
      await pumpScreen(tester);
      await tapMic(tester);
      await engine.push(
        tester,
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );

      expect(
        tester
            .widget<FilledButton>(find.byKey(DiagnoseKeys.diagnoseButton))
            .onPressed,
        isNull,
      );

      await tapMic(tester);

      expect(
        tester
            .widget<FilledButton>(find.byKey(DiagnoseKeys.diagnoseButton))
            .onPressed,
        isNotNull,
        reason:
            'and it must become live once dictation ends — a programmatic '
            'controller write does not fire onChanged, so nothing else would '
            're-evaluate it',
      );
    });
  });

  group('the work order on screen', () {
    testWidgets('all four fields are shown, empty', (tester) async {
      await pumpScreen(tester);

      expect(find.byKey(WorkOrderKeys.panel), findsOneWidget);
      for (final field in WorkOrderField.values) {
        expect(find.byKey(WorkOrderKeys.field(field)), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(WorkOrderKeys.field(field)))
              .controller!
              .text,
          '',
          reason: field.name,
        );
      }
      expect(find.text('0 of 4'), findsOneWidget);
    });

    testWidgets('an agent recording fills the fields on screen', (
      tester,
    ) async {
      final container = await pumpScreen(tester);

      container.read(workOrderFormProvider.notifier).applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: {
          'fault_code': 'E-102',
          'required_parts': 'BRK-990-XP',
        },
      });
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(
              find.byKey(WorkOrderKeys.field(WorkOrderField.faultCode)),
            )
            .controller!
            .text,
        'E-102',
      );
      expect(find.text('2 of 4'), findsOneWidget);
    });

    testWidgets('typing into a field records it as the technician\'s', (
      tester,
    ) async {
      final container = await pumpScreen(tester);

      await tester.enterText(
        find.byKey(WorkOrderKeys.field(WorkOrderField.technicianHours)),
        '1.5',
      );
      await tester.pumpAndSettle();

      final state = container.read(workOrderFormProvider);
      expect(state.textOf(WorkOrderField.technicianHours), '1.5');
      expect(
        state.fields[WorkOrderField.technicianHours]!.origin,
        FormFieldOrigin.technician,
        reason:
            'the state → controller sync must not echo back through onChanged '
            'and relabel an agent value as a technician one',
      );
    });

    // **Review finding R0-F4.** `WorkOrderFormState.rejected` was dead on every
    // production path while its docstring named a reader. It now reaches the state
    // and this line, so what the model got wrong is visible beside the form.
    testWidgets('a refused field is reported on the panel', (tester) async {
      final container = await pumpScreen(tester);

      container.read(workOrderFormProvider.notifier).applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: {'fault_code': 'E-102'},
        RecordWorkOrderFieldsTool.refusedKey: [
          {
            'field': 'elevator_colour',
            'error': 'unknown_field',
            'message': 'not a field of the work order',
          },
        ],
      });
      await tester.pumpAndSettle();

      expect(find.byKey(WorkOrderKeys.refusals), findsOneWidget);
      expect(
        find.textContaining('1 value this form has no field for'),
        findsOneWidget,
      );
      // The message is written for the model, so it does not reach the screen —
      // `_ResultPanel`'s decision about refused tool calls, applied to fields.
      expect(
        find.textContaining('not a field of the work order'),
        findsNothing,
      );
    });

    testWidgets('no refusals means no line', (tester) async {
      final container = await pumpScreen(tester);

      container.read(workOrderFormProvider.notifier).applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: {'fault_code': 'E-102'},
      });
      await tester.pumpAndSettle();

      expect(find.byKey(WorkOrderKeys.refusals), findsNothing);
    });

    testWidgets('a conflicting agent value is offered, not applied', (
      tester,
    ) async {
      final container = await pumpScreen(tester);
      await tester.enterText(
        find.byKey(WorkOrderKeys.field(WorkOrderField.faultCode)),
        'E-999',
      );
      await tester.pumpAndSettle();

      container.read(workOrderFormProvider.notifier).applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: {'fault_code': 'E-102'},
      });
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(
              find.byKey(WorkOrderKeys.field(WorkOrderField.faultCode)),
            )
            .controller!
            .text,
        'E-999',
      );
      final suggestion = find.byKey(
        WorkOrderKeys.suggestion(WorkOrderField.faultCode),
      );
      expect(suggestion, findsOneWidget);
      // Scoped to the suggestion row: `E-102` is also the inquiry field's *hint*,
      // so an unscoped `textContaining` matches three widgets and would have
      // passed with the offer never rendered.
      expect(
        find.descendant(of: suggestion, matching: find.textContaining('E-102')),
        findsOneWidget,
      );
    });

    testWidgets('taking the suggestion puts it in the field', (tester) async {
      final container = await pumpScreen(tester);
      await tester.enterText(
        find.byKey(WorkOrderKeys.field(WorkOrderField.faultCode)),
        'E-999',
      );
      await tester.pumpAndSettle();
      container.read(workOrderFormProvider.notifier).applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: {'fault_code': 'E-102'},
      });
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(WorkOrderKeys.acceptSuggestion(WorkOrderField.faultCode)),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(
              find.byKey(WorkOrderKeys.field(WorkOrderField.faultCode)),
            )
            .controller!
            .text,
        'E-102',
      );
      expect(
        find.byKey(WorkOrderKeys.suggestion(WorkOrderField.faultCode)),
        findsNothing,
      );
    });

    testWidgets('keeping mine drops the offer and leaves the field', (
      tester,
    ) async {
      final container = await pumpScreen(tester);
      await tester.enterText(
        find.byKey(WorkOrderKeys.field(WorkOrderField.faultCode)),
        'E-999',
      );
      await tester.pumpAndSettle();
      container.read(workOrderFormProvider.notifier).applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: {'fault_code': 'E-102'},
      });
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(WorkOrderKeys.dismissSuggestion(WorkOrderField.faultCode)),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(
              find.byKey(WorkOrderKeys.field(WorkOrderField.faultCode)),
            )
            .controller!
            .text,
        'E-999',
      );
      expect(
        find.byKey(WorkOrderKeys.suggestion(WorkOrderField.faultCode)),
        findsNothing,
      );
    });
  });

  group('the clarification reaches the screen', () {
    testWidgets('a question the agent asks opens over the screen', (
      tester,
    ) async {
      final container = await pumpScreen(tester);

      container.read(workOrderFormProvider.notifier).applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: {'fault_code': 'E-102'},
        RecordWorkOrderFieldsTool.askedKey: {
          'field': 'required_parts',
          'question': 'Which filter did you use?',
          'options': ['12-inch mesh', '14-inch carbon'],
        },
      });
      await tester.pumpAndSettle();

      expect(find.byKey(ClarificationKeys.dialog), findsOneWidget);

      await tester.tap(find.byKey(ClarificationKeys.option(1)));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(
              find.byKey(WorkOrderKeys.field(WorkOrderField.requiredParts)),
            )
            .controller!
            .text,
        '14-inch carbon',
      );
    });
  });
}

/// A fixed warm-up state, loading nothing.
class _StubWarmup extends EngineWarmupController {
  _StubWarmup(this._state);

  final EngineWarmupState _state;

  @override
  EngineWarmupState build() => _state;

  @override
  Future<void> warmUp() async {}
}

/// An `LlmEngine` that is ready and never asked to do anything — the warm-up
/// state needs one and no test here runs a diagnosis.
class _InertEngine implements LlmEngine {
  const _InertEngine();

  @override
  bool get isReady => true;

  @override
  Future<void> initialize() async {}

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) => const Stream<LlmEvent>.empty();

  @override
  Future<void> dispose() async {}
}

/// An [SttEngine] a test pushes transcripts through, with a widget-aware [push].
class _ScriptedSttEngine implements SttEngine {
  StreamController<SttTranscript>? _out;
  StreamSubscription<MicFrame>? _frames;
  bool _ready = false;

  @override
  bool get isReady => _ready;

  @override
  Future<void> initialize() async => _ready = true;

  /// Emits [transcript] and turns the resulting state into frames.
  Future<void> push(WidgetTester tester, SttTranscript transcript) async {
    final out = _out;
    if (out != null && !out.isClosed) out.add(transcript);
    await tester.pumpAndSettle();
  }

  @override
  Stream<SttTranscript> transcribe(Stream<MicFrame> frames) {
    final out = StreamController<SttTranscript>();
    _out = out;
    _frames = frames.listen(
      (_) {},
      onError: (Object error) {
        if (!out.isClosed) {
          out.addError(error);
          out.close();
        }
      },
      onDone: () {
        if (!out.isClosed) out.close();
      },
    );
    return out.stream;
  }

  @override
  Future<void> dispose() async {
    await _frames?.cancel();
    final out = _out;
    if (out != null && !out.isClosed) await out.close();
  }
}

/// The microphone, scripted. One raw stream per capture, closed by `stop`.
class _ScriptedAudioInput implements AudioInput {
  bool permission = true;
  int startStreamCalls = 0;
  StreamController<Uint8List>? _raw;

  @override
  Future<bool> hasPermission({bool request = true}) async => permission;

  @override
  Future<Stream<Uint8List>> startStream(PcmAudioFormat format) async {
    startStreamCalls++;
    final raw = StreamController<Uint8List>.broadcast();
    _raw = raw;
    return raw.stream;
  }

  @override
  Future<void> watchFormat(void Function(String description) onCoerced) async {}

  @override
  Future<void> stop() async {
    final raw = _raw;
    _raw = null;
    if (raw != null && !raw.isClosed) await raw.close();
  }

  @override
  Future<void> dispose() async => stop();
}
