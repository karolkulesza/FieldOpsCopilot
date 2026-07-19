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
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:field_ops_copilot/services/models/providers.dart';
import 'package:field_ops_copilot/viewmodels/dictation_viewmodel.dart';
import 'package:field_ops_copilot/viewmodels/work_order_form_viewmodel.dart';
import 'package:field_ops_copilot/views/components/clarification_dialog.dart';
import 'package:field_ops_copilot/views/components/model_readiness_banner.dart';
import 'package:field_ops_copilot/views/components/work_order_form_panel.dart';
import 'package:field_ops_copilot/views/diagnose_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Voice and the work order on the screen: the microphone button, the transcript
/// reaching the inquiry field, and the work order filling in.
///
/// Separate from `diagnose_screen_test.dart` deliberately — that file owns the
/// diagnose flow's properties and its harness is built around injecting a
/// `FieldJobState`. What is asserted here is the voice-and-form layer, over the
/// *real* dictation and form
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

    /// The readiness state the *device* was in when the keyboard overflow was
    /// reported: no LLM configured, so the banner carries the two-line
    /// "Set FIELDOPS_MODEL_URI…" row and the engine status row reads "no verified
    /// weights". That chrome is ~90px taller than the ready state every other test
    /// here uses, and it is the difference between reproducing the overflow and
    /// writing a test that passes because there was never one.
    bool modelReady = true,
  }) async {
    tester.view.physicalSize = const Size(1180, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        modelInstallStatusProvider.overrideWith(
          (ref, modelId) async => modelReady
              ? ModelInstallStatus.ready
              // The STT set is installed on the device; the LLM is not.
              : (modelId == ModelCatalog.sttZipformerId
                    ? ModelInstallStatus.ready
                    : ModelInstallStatus.absent),
        ),
        seedOutcomeProvider.overrideWith(
          (ref) async => const SeedSkipped(storedRevision: 1, assetRevision: 1),
        ),
        engineWarmupControllerProvider.overrideWith(
          () => _StubWarmup(
            modelReady
                ? const EngineReady(_InertEngine())
                : const EngineUnavailable(),
          ),
        ),
        micCaptureProvider.overrideWith((ref) {
          // **`stallTimeout: null`, and it is the test that is wrong without
          // it rather than the production default.** The watchdog is a real
          // `Timer(5s)` armed for the whole of a capture, and `flutter_test`
          // fails any test that ends with one pending — which `mic_capture.dart`'s
          // own source predicts in as many words ("the dictation UI puts this
          // inside a widget"). Every test here ends mid-capture or just after one, so the
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
  /// enough — and note that a *typed* edit now also closes a capture, so
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
    // Settle *first*: `start()` is a chain of awaits and the input does not exist
    // until `startStream` has been called, so an emit before this lands nowhere.
    await settleAsync(tester);
    // A real microphone delivers audio the moment it is open, and
    // `DictationPhase.listening` now means *audio is arriving* rather than "the
    // input was asked for" — the demo device takes 1227ms to hand one over, and a
    // technician talking over that window loses the start of their sentence. A
    // double that never delivers a frame can no longer reach `listening`, and that
    // is right: neither can a real microphone that never delivers one.
    input.emit(List<int>.filled(320, 1));
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

    // The screen's own no-animation rule, extended to the dictation path — the
    // UI isolate measurably drops frames while tokens stream, and the
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

    // The screen's own comment argues the field is not
    // read-only while dictating "because a technician who sees `FALK CODE` land
    // has to be able to fix it" — and that was the one case that used to
    // fail: `_onDictation` rebuilds the whole line from `base + transcript` on
    // every state change, so the next partial wiped the correction. Two tests,
    // because there are two ways to lose it.
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
      // The second way to lose it: no further speech at all, just the
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

  group('clearing the inquiry', () {
    testWidgets('the button is absent until there is something to clear', (
      tester,
    ) async {
      await pumpScreen(tester);
      expect(find.byKey(DiagnoseKeys.clearInquiry), findsNothing);

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(DiagnoseKeys.clearInquiry), findsOneWidget);
    });

    testWidgets('one tap empties the field and disables Diagnose', (
      tester,
    ) async {
      await pumpScreen(tester);
      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating, E-102',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(DiagnoseKeys.diagnoseButton))
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(DiagnoseKeys.clearInquiry));
      await tester.pumpAndSettle();

      expect(inquiryText(tester), '');
      // **The half a `clear()` alone would miss.** `controller.clear()` is a
      // programmatic write and does not fire `onChanged`, so without the
      // rebuild the text would vanish while Diagnose stayed live over an empty
      // inquiry — the same asymmetry `_onDictation` documents, arriving through
      // a different door.
      expect(
        tester
            .widget<FilledButton>(find.byKey(DiagnoseKeys.diagnoseButton))
            .onPressed,
        isNull,
        reason: 'an empty inquiry must not be diagnosable',
      );
      expect(find.byKey(DiagnoseKeys.clearInquiry), findsNothing);
    });

    testWidgets('clearing during a capture takes the field and stops the mic', (
      tester,
    ) async {
      // Clearing **is** an edit, so it takes the field on the same terms typing
      // does (R0-F1). A clear that left the microphone open would go on filling
      // a field the technician had just emptied; one that left the mirror
      // attached would be undone by the next partial.
      final c = await pumpScreen(tester);
      await tapMic(tester);
      await engine.push(
        tester,
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );
      expect(inquiryText(tester), 'THE CABIN IS VIBRATING');
      expect(c.read(dictationControllerProvider).isActive, isTrue);

      await tester.tap(find.byKey(DiagnoseKeys.clearInquiry));
      await settleAsync(tester);

      expect(inquiryText(tester), '');
      expect(
        c.read(dictationControllerProvider).isActive,
        isFalse,
        reason: 'the microphone must not keep writing into a cleared field',
      );
    });

    testWidgets('a capture after a clear starts from empty', (tester) async {
      // The transcript is not carried over: `start()` resets it and
      // `_onDictation` re-reads the base from the field, which is now blank. If
      // either stopped being true, the cleared words would reappear on the next
      // capture — which is the failure a technician would read as the clear
      // button not working.
      await pumpScreen(tester);
      await tapMic(tester);
      await engine.push(
        tester,
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );
      await tester.tap(find.byKey(DiagnoseKeys.clearInquiry));
      await settleAsync(tester);

      await tapMic(tester);
      await engine.push(
        tester,
        const SttTranscript('E ONE OH TWO', isFinal: true),
      );

      expect(inquiryText(tester), 'E ONE OH TWO');
    });
  });

  // **Reported from the demo iPad: `BOTTOM OVERFLOWED BY 64 PIXELS` with the
  // software keyboard up.** `Scaffold` shrinks the body for the keyboard inset,
  // and the two panels are `Expanded` — so they had already collapsed to zero and
  // what did not fit was the *fixed* chrome. Reproduced here at the device's own
  // geometry before it was fixed (12px in a test, 64 on hardware, because the
  // device's banner carries two model rows of longer text).
  group('the keyboard does not overflow the screen', () {
    /// The keyboard inset from the screenshot, measured off it rather than
    /// guessed: the keyboard occupies the bottom ~51% of an 820pt landscape iPad,
    /// so 420. Applied as a *view inset*, which is what the platform reports and
    /// what `Scaffold` subtracts, rather than by shrinking the surface — shrinking
    /// would model a smaller device, and this is a full-size device with less room.
    ///
    /// **420 specifically, because it is where the defect reproduces.** Sweeping
    /// the inset against the unfixed layout: 360 and 400 are clean, **420
    /// overflows by 4px**, and the first guess of 360 produced a test that passed
    /// with the fix reverted — a test written to bind a layout defect that could
    /// not see it. The device reported 64px rather than 4 because its banner was
    /// taller still; the mechanism is the same and the margin is not.
    Future<void> raiseKeyboard(WidgetTester tester) async {
      tester.view.viewInsets = const FakeViewPadding(bottom: 420);
      await tester.pumpAndSettle();
    }

    testWidgets('with the keyboard up, nothing overflows', (tester) async {
      await pumpScreen(tester, modelReady: false);

      await raiseKeyboard(tester);

      expect(
        tester.takeException(),
        isNull,
        reason:
            'a RenderFlex overflow paints the yellow-and-black stripe on a '
            'device and silently clips in release',
      );
    });

    testWidgets('the inquiry field and Diagnose survive the keyboard', (
      tester,
    ) async {
      await pumpScreen(tester, modelReady: false);
      await raiseKeyboard(tester);

      // What a technician is actually doing when the keyboard is up. Losing the
      // readiness banner to make room is the intended trade; losing these is not.
      expect(find.byKey(DiagnoseKeys.inquiryField), findsOneWidget);
      expect(find.byKey(DiagnoseKeys.diagnoseButton), findsOneWidget);
      expect(find.byKey(DiagnoseKeys.dictateButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with the keyboard down the layout is unchanged', (
      tester,
    ) async {
      // The control: loose flex must take its natural height when there is room,
      // or the fix would have quietly shrunk the banner on every screen.
      await pumpScreen(tester, modelReady: false);

      expect(find.byType(ModelReadinessBanner), findsOneWidget);
      expect(find.byKey(DiagnoseKeys.engineStatus), findsOneWidget);
      expect(find.byKey(WorkOrderKeys.panel), findsOneWidget);
      expect(find.byKey(DiagnoseKeys.resultPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
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

    // **Reported from the demo iPad, and the screenshot is the argument.** A
    // brake fault was diagnosed and recorded four fields. A door fault was then
    // diagnosed on the same screen: it overwrote `fault_code` and
    // `required_parts` with E-305 and BELT-330-DRV, and left `1.5` hours and
    // `lockout/tagout verified` sitting under them from the *brake* job — each
    // still drawn with the agent-origin marker, so the panel asserted the model
    // had recorded them for the door fault. Nothing on screen was invented;
    // every value had really been produced by the agent, one inquiry earlier.
    // That is what made it convincing, and a work order is signed off.
    testWidgets('a new diagnosis drops agent fields and keeps typed ones', (
      tester,
    ) async {
      final container = await pumpScreen(tester);

      await tester.enterText(
        find.byKey(WorkOrderKeys.field(WorkOrderField.technicianHours)),
        '1.5',
      );
      container.read(workOrderFormProvider.notifier).applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: {'fault_code': 'E-102'},
      });
      await tester.pumpAndSettle();
      expect(find.text('2 of 4'), findsOneWidget);

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'the doors keep re-opening on car two',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(DiagnoseKeys.diagnoseButton));
      await tester.pump();

      final state = container.read(workOrderFormProvider);
      expect(
        state.textOf(WorkOrderField.faultCode),
        '',
        reason:
            "the previous inquiry's fault code must not survive into this one",
      );
      expect(
        state.textOf(WorkOrderField.technicianHours),
        '1.5',
        reason:
            'a new question about the same job is not an instruction to throw '
            "away the technician's own work — that is `reset`, and a new job",
      );
      // And the visible half, because the controllers are what the technician
      // reads and they are synced separately from the state.
      expect(
        tester
            .widget<TextField>(
              find.byKey(WorkOrderKeys.field(WorkOrderField.faultCode)),
            )
            .controller!
            .text,
        '',
      );
      expect(find.text('1 of 4'), findsOneWidget);

      // Whatever the stubbed engine does with the run itself is not this test's
      // subject; the clearing happens before it and must not depend on it.
      tester.takeException();
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

  /// Pushes raw PCM as the plugin would. Even-length only: `MicCapture` emits
  /// whole frames and carries a partial one over.
  ///
  /// Delivered at an **odd `offsetInBytes`**, because that is what the device
  /// delivered and `Uint8List.fromList` never does — see the long note on the
  /// same helper in `dictation_viewmodel_test.dart`. A frame read through an
  /// `Int16List` view threw here and stopped dictation on the first frame, with
  /// every test green.
  void emit(List<int> bytes) {
    const offset = 5;
    final backing = Uint8List(offset + bytes.length)
      ..setRange(offset, offset + bytes.length, bytes);
    _raw?.add(Uint8List.sublistView(backing, offset));
  }

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
