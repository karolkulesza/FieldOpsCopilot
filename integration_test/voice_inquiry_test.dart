import 'dart:async';

import 'package:field_ops_copilot/app.dart';
import 'package:field_ops_copilot/models/form_state_model.dart';
import 'package:field_ops_copilot/services/audio/mic_capture.dart';
import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:field_ops_copilot/services/audio/providers.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_provisioner.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:field_ops_copilot/viewmodels/dictation_viewmodel.dart';
import 'package:field_ops_copilot/views/components/work_order_form_panel.dart';
import 'package:field_ops_copilot/views/diagnose_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// TC-VOICE-FILL-01 — a spoken inquiry becoming the text in the inquiry field, on
/// a device, through the real recogniser.
///
/// ```sh
/// flutter test integration_test/voice_inquiry_test.dart -d <device>
///
/// # On a WIRELESSLY tethered iOS device the above cannot launch the app
/// # ("Cannot start app on wirelessly tethered iOS device"), and `flutter test`
/// # has no `--publish-port` flag despite the error suggesting one. Run the file
/// # through `flutter run`, which does — the README says the same at greater
/// # length, and a cable avoids the whole thing.
/// flutter run integration_test/voice_inquiry_test.dart -d <device> --publish-port
/// ```
///
/// **No `--dart-define`s.** The STT source and its four SHA-256 pins are committed
/// on Task 2.0's catalog entry, and this test provisions the 43.65MB set if it is
/// absent. It does not need the LLM: the screen renders and dictates whether or not
/// the model is installed, which is itself worth having on the record.
///
/// **The audio is the committed fixture and the microphone is substituted, and that
/// is the design rather than a shortcut.** TC-MIC-01 owns "real hardware delivers
/// real PCM" and TC-STT-STRM-01 owns "the fixture transcribes". What neither owns,
/// and what only this can, is the *join* — real weights on a real background
/// isolate, driving the real `DictationController` and the real screen, all the way
/// to characters in a `TextField`. A live microphone here would make the assertion
/// depend on the room, which is the same reason `stt_test.dart` gives for using the
/// fixture.
///
/// The substitution is exactly one class deep: `AudioInput`, Task 2.1's seam. Above
/// it `MicCapture` normalises frames, bounds the backlog and accounts for gaps
/// exactly as it does on a live capture, so what is bypassed is the driver and not
/// the pipeline.
///
/// ⚠️ **This has never run on hardware.** What is written here is the test; what it
/// asserts on the host is nothing, because the recogniser cannot load there without
/// a `nativeLibraryPath` and production always passes null. It belongs to the same
/// owed-device-run category as TC-MIC-01 was, and the README says so.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TC-VOICE-FILL-01 — dictated audio becomes the inquiry text',
    (tester) async {
      await _installSttModel();
      final pcm = await _fixturePcm();
      final input = _FixtureAudioInput(pcm);

      final container = ProviderContainer(
        overrides: [
          // The one substitution. See the library doc.
          micCaptureProvider.overrideWith((ref) {
            final capture = MicCapture(input: input);
            ref.onDispose(capture.dispose);
            return capture;
          }),
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

      final watch = Stopwatch()..start();
      await tester.tap(find.byKey(DiagnoseKeys.dictateButton));
      await _waitFor(
        tester,
        () =>
            container.read(dictationControllerProvider).phase !=
            DictationPhase.starting,
        describe: 'the capture to leave `starting`',
      );
      expect(
        container.read(dictationControllerProvider).phase,
        DictationPhase.listening,
        reason:
            'two different failures land here and the phase tells them apart: '
            '`unavailable` means no verified weights, which the provisioning '
            'above should have made impossible; `starting` means the microphone '
            'opened and no audio followed, because `listening` means audio is '
            'arriving rather than that the input was asked for',
      );

      // Let the fixture play out through the real recogniser.
      await input.playToEnd();
      await _settle(tester, rounds: 40);
      await tester.tap(find.byKey(DiagnoseKeys.dictateButton));
      await _settle(tester, rounds: 20);
      watch.stop();

      final dictation = container.read(dictationControllerProvider);
      final inquiry = tester
          .widget<TextField>(find.byKey(DiagnoseKeys.inquiryField))
          .controller!
          .text;

      debugPrint(
        '[TC-VOICE-FILL-01] ${watch.elapsedMilliseconds}ms, '
        'phase ${dictation.phase.name}, '
        '${dictation.committed.length} utterance(s)',
      );
      debugPrint('[TC-VOICE-FILL-01] inquiry field: "$inquiry"');

      // Fuzzy containment, as the tier requires and as TC-STT-STRM-01 explains: a
      // 20M int8 model mis-hears "fault code" as "FALK CODE" on this fixture, so
      // the assertion is the two words that have to survive for the *downstream*
      // path to work at all.
      final text = inquiry.toLowerCase();
      expect(text, contains('102'), reason: 'the fault code must survive');
      expect(text, contains('error'));

      // The dictation ended cleanly rather than being left open by the stop.
      expect(dictation.phase, DictationPhase.idle);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'a dictated inquiry leaves the work order untouched until the agent fills it',
    (tester) async {
      // Not an AC. It exists because the two halves of Task 2.3 are wired into the
      // same screen and the cheapest way for the voice half to be wrong is for it
      // to write somewhere it should not — the form is filled by the *tool*, never
      // by the transcript.
      await _installSttModel();
      final pcm = await _fixturePcm();
      final input = _FixtureAudioInput(pcm);

      final container = ProviderContainer(
        overrides: [
          micCaptureProvider.overrideWith((ref) {
            final capture = MicCapture(input: input);
            ref.onDispose(capture.dispose);
            return capture;
          }),
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

      await tester.tap(find.byKey(DiagnoseKeys.dictateButton));
      await _waitFor(
        tester,
        () =>
            container.read(dictationControllerProvider).phase !=
            DictationPhase.starting,
        describe: 'the capture to leave `starting`',
      );
      await input.playToEnd();
      await _settle(tester, rounds: 40);
      await tester.tap(find.byKey(DiagnoseKeys.dictateButton));
      await _settle(tester, rounds: 20);

      for (final field in WorkOrderField.values) {
        expect(
          tester
              .widget<TextField>(find.byKey(WorkOrderKeys.field(field)))
              .controller!
              .text,
          '',
          reason:
              '${field.wireName} was filled by something other than the tool',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

/// Gives real asynchronous work — the isolate round trips, the recogniser — actual
/// time, then turns the result into frames.
///
/// `pumpAndSettle` alone is not enough: a widget test's clock is faked, so it stops
/// the moment no frame is scheduled, which is true while the worker is decoding.
/// Measured on the host against `MicCaptureSession.stop`: advancing the fake clock
/// by 800ms left the stop unresolved, and eight real 20ms slices resolved it.
Future<void> _settle(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
}

/// Pumps until [condition] holds, or fails after [within].
///
/// A **condition rather than a duration**, because every number this wait could be
/// written as is a number measured on one device. The demo iPad takes 727ms from
/// the tap to the recogniser attaching — 190ms of it opening the microphone and
/// 536ms loading the model — and a fixed settle that happens to exceed that on one
/// machine is a test that passes by luck and fails on a colder run or a slower
/// disk. Task 2.2's own row records the load varying 359–530ms across ten runs on
/// one host.
Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration within = const Duration(seconds: 15),
  required String describe,
}) async {
  final deadline = DateTime.now().add(within);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${within.inSeconds}s waiting for $describe');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
}

/// Ensures the four STT files are present and hash-verified.
Future<void> _installSttModel() async {
  final descriptor = ModelCatalog.byId(ModelCatalog.sttZipformerId)!;
  final storage = await ModelStorage.openDefault();
  await storage.prepare();
  final provisioner = ModelProvisioner(storage: storage);
  addTearDown(provisioner.dispose);

  var status = await provisioner.statusOf(descriptor);
  if (status != ModelInstallStatus.ready) {
    debugPrint('[voice] provisioning ${descriptor.files.length} files…');
    await provisioner.provision(descriptor);
    status = await provisioner.statusOf(descriptor);
  }
  expect(status, ModelInstallStatus.ready);
}

/// The recorded fixture's PCM payload, read out of the app's asset bundle.
///
/// Through the bundle rather than the filesystem: an integration test runs inside
/// the app, where the repository's `test/` directory does not exist.
Future<Uint8List> _fixturePcm() async {
  final data = await rootBundle.load('test/fixtures/e102_utterance.wav');
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final view = ByteData.sublistView(bytes);
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = view.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      expect(view.getUint16(body + 2, Endian.little), 1, reason: 'mono');
      expect(view.getUint32(body + 4, Endian.little), 16000, reason: '16 kHz');
      expect(view.getUint16(body + 14, Endian.little), 16, reason: '16-bit');
    } else if (id == 'data') {
      return Uint8List.sublistView(bytes, body, body + size);
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  fail('the fixture has no RIFF data chunk');
}

/// An [AudioInput] that plays a fixture instead of opening the microphone.
///
/// Emits at `MicCapture`'s own frame size and in real time rather than all at
/// once, so the backlog, the pause-aware pump and the recogniser's endpointer all
/// see the cadence a live capture produces. Dumping ten seconds of audio in one
/// buffer would drop most of it on the two-second backlog bound and prove nothing.
class _FixtureAudioInput implements AudioInput {
  _FixtureAudioInput(this._pcm);

  final Uint8List _pcm;
  StreamController<Uint8List>? _raw;
  Future<void>? _playing;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  /// **Playback begins when the pipeline subscribes, not when a test asks for it.**
  ///
  /// It used to begin in [playToEnd], and that made this input unlike a microphone
  /// in the one way that now matters: a real one delivers from the moment it is
  /// open, and `DictationPhase.listening` means *audio is arriving* rather than
  /// *the input was asked for*. So the assertion between the tap and the playback —
  /// the one checking the screen reached `listening` — could never pass, and the
  /// first hardware run of this file failed on it with the app behaving correctly.
  ///
  /// The same gap, in the same direction, that let a crash reach a device: a double
  /// gentler than the hardware is a test that cannot fail. Recorded on Task 2.3's
  /// row in the sprint plan.
  ///
  /// `onListen` rather than a call inside [startStream], and the difference is not
  /// stylistic — this is a **broadcast** controller, so anything added before the
  /// consumer subscribes is dropped on the floor. Starting playback here is what
  /// makes "the first chunk of the fixture" and "the first frame the recogniser
  /// sees" the same bytes.
  @override
  Future<Stream<Uint8List>> startStream(PcmAudioFormat format) async {
    expect(
      format,
      PcmAudioFormat.sttMono16k,
      reason: 'the fixture is 16 kHz mono; anything else decodes as noise',
    );
    late final StreamController<Uint8List> raw;
    // Cleared first: one playback per capture, so a second `start()` on this input
    // plays again instead of handing back the previous session's finished future.
    _playing = null;
    raw = StreamController<Uint8List>.broadcast(
      onListen: () => _playing ??= _play(raw),
    );
    _raw = raw;
    return raw.stream;
  }

  /// Waits for the fixture to finish playing.
  Future<void> playToEnd() async {
    final playing = _playing;
    if (playing == null) {
      fail(
        'playToEnd before anything subscribed — the capture never attached, so '
        'no audio was ever going to arrive',
      );
    }
    await playing;
  }

  /// Feeds the whole fixture through, one 100ms chunk at a time.
  ///
  /// The wait comes **before** each chunk rather than after it, which is both the
  /// safer and the truer order. Safer: this runs from `onListen`, and adding an
  /// event synchronously inside that callback relies on the subscription already
  /// being registered when it fires — true of `dart:async` today, and not a
  /// property worth depending on. Truer: a capture device fills a buffer and then
  /// delivers it, so the first frame lands one buffer period after the input opens,
  /// which is what the device logs show (~50ms behind `attached`).
  Future<void> _play(StreamController<Uint8List> raw) async {
    const chunk = Duration(milliseconds: 100);
    final size = PcmAudioFormat.sttMono16k.byteCountFor(chunk);
    for (var offset = 0; offset < _pcm.length; offset += size) {
      await Future<void>.delayed(chunk);
      if (raw.isClosed) return;
      raw.add(
        Uint8List.sublistView(
          _pcm,
          offset,
          offset + size > _pcm.length ? _pcm.length : offset + size,
        ),
      );
    }
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
  Future<void> dispose() => stop();
}
