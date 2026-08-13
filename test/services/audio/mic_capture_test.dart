import 'dart:async';
import 'dart:typed_data';

import 'package:field_ops_copilot/services/audio/mic_capture.dart';
import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

/// Unit-tier coverage for Task 2.1.
///
/// The device AC (**TC-MIC-01**) asserts the one thing only hardware can answer:
/// that a real microphone produces real PCM. Everything *around* that — the
/// permission gate, frame normalisation, the bounded backlog, the lifecycle, and
/// what happens when the microphone goes away mid-utterance — is decided by
/// [MicCapture] over the [AudioInput] seam, and is bound here.
///
/// The double below is deliberately a **broadcast** controller with no
/// backpressure, because that is the shape `record` 7.1.1 actually returns
/// (`_StreamMixin._startRecordStream`). Testing against a well-behaved
/// single-subscription stream would test a world the plugin does not provide.
void main() {
  group('permission gate', () {
    test('a denial is a value, and the microphone is never opened', () async {
      final input = _ScriptedAudioInput(permission: false);
      final capture = MicCapture(input: input);

      final result = await capture.start();

      expect(result, isA<MicPermissionDenied>());
      expect(
        input.startStreamCalls,
        0,
        reason:
            'asking the recorder for audio it may not take is the bug this '
            'gate exists to prevent',
      );
    });

    test('a failure to *ask* is not a denial', () async {
      // The one that actually happens is a missing platform usage declaration.
      // Reporting that as "permission denied" sends an operator to Settings for
      // a toggle that is not there.
      final input = _ScriptedAudioInput()
        ..permissionError = Exception('MissingPluginException');
      final capture = MicCapture(input: input);

      final result = await capture.start();

      expect(result, isA<MicCaptureUnavailable>());
      expect(
        (result as MicCaptureUnavailable).message,
        contains('MissingPluginException'),
      );
      expect(input.startStreamCalls, 0);
    });

    test(
      'a granted permission opens the microphone in the STT format',
      () async {
        final input = _ScriptedAudioInput();
        final capture = MicCapture(input: input);

        final result = await capture.start();

        expect(result, isA<MicCaptureStarted>());
        expect(input.startStreamCalls, 1);
        expect(input.requestedFormat, PcmAudioFormat.sttMono16k);
        expect(
          (result as MicCaptureStarted).session.format,
          PcmAudioFormat.sttMono16k,
        );
      },
    );

    test('a microphone that refuses to open is unavailable, not denied', () async {
      final input = _ScriptedAudioInput()
        ..startError = Exception('input in use by another app');
      final capture = MicCapture(input: input);

      final result = await capture.start();

      expect(result, isA<MicCaptureUnavailable>());
      expect(
        (result as MicCaptureUnavailable).message,
        contains('input in use by another app'),
      );
      // And the recorder is handed back. `watchFormat` can succeed and
      // `startStream` fail after the platform has already taken the microphone,
      // and a caller told "unavailable" holds no session to stop with — so
      // without this the input stays open until `dispose`. Raised as a
      // non-blocking note in review round 0; the first fix for it shipped with
      // no test and a mutation emptying the cleanup survived.
      expect(input.stopCalls, 1);
    });

    test('a cleanup failure does not mask why the microphone is unavailable', () async {
      // The cleanup is best-effort by construction: the input may never have
      // opened, in which case `stop` is entitled to throw. What the caller needs is
      // the original reason, not a second failure from the tidying up.
      //
      // An `Exception` specifically, because the recovery is `on Exception` and
      // not `on Object` — Task 1.5's rule, that an `Error` means the app is broken
      // and must not be swallowed. The first draft of this test threw a
      // `StateError` and failed, which is that convention working rather than a
      // defect in the code.
      final input = _ScriptedAudioInput()
        ..startError = Exception('input in use by another app')
        ..stopError = Exception('nothing to stop');
      final capture = MicCapture(input: input);

      final result = await capture.start();

      expect(result, isA<MicCaptureUnavailable>());
      expect(
        (result as MicCaptureUnavailable).message,
        contains('input in use by another app'),
      );
    });
  });

  group('frame normalisation', () {
    test('delivers what the microphone produced', () async {
      final harness = await _Harness.start();

      harness.input.emit([1, 2, 3, 4]);
      harness.input.emit([5, 6]);
      await harness.session.stop();

      expect(await harness.byteRuns, [
        [1, 2, 3, 4],
        [5, 6],
      ]);
    });

    test('drops empty buffers rather than forwarding them', () async {
      // **iOS** can produce one, when a tap buffer carries no frames:
      // `Pcm16BitsEncoder.encode` returns `[bytes]` with `bytes` empty, and
      // `handleTap` sends every element. Android cannot — review finding R0-F8.3
      // refuted that half of an earlier version of this comment, because
      // `RecordThread` guards `if (buffer.isNotEmpty())` before encoding. One
      // platform is reason enough: an empty frame is not audio, and a recogniser
      // would have to special-case it if it arrived.
      final harness = await _Harness.start();

      harness.input.emit([]);
      harness.input.emit([1, 2]);
      harness.input.emit([]);
      await harness.session.stop();

      final frames = await harness.frames;
      expect(frames, hasLength(1));
      expect(frames.single.bytes, [1, 2]);
      expect(
        frames.every((frame) => frame.bytes.isNotEmpty),
        isTrue,
        reason: 'MicFrame.bytes documents itself as never empty',
      );
    });

    test('carries a split sample instead of emitting half of one', () async {
      // A frame boundary is the only place a PCM stream may be cut. Emit one byte
      // at a time and the naive implementation forwards half-samples, at which
      // point every sample after the splice decodes from the wrong two bytes.
      final harness = await _Harness.start();

      for (final byte in [1, 2, 3, 4, 5]) {
        harness.input.emit([byte]);
      }
      await harness.session.stop();

      final frames = await harness.frames;
      expect(frames.map((frame) => frame.bytes.length), everyElement(isNot(0)));
      for (final frame in frames) {
        expect(
          frame.bytes.length.remainder(2),
          0,
          reason:
              'a 16-bit sample is two bytes; a frame is a whole number of them',
        );
      }
      // Nothing invented, nothing reordered, and only the trailing odd byte held
      // back — it is still a partial sample when the capture ends, so it is
      // dropped rather than padded into a sample nobody spoke.
      expect(_flatten(frames), [1, 2, 3, 4]);
    });

    test('carries to a whole frame on a multi-channel stream', () async {
      // Cutting a stereo stream at a *sample* boundary that is not a *frame*
      // boundary swaps left and right for everything after it — audible, and not
      // caught by any even-length assertion.
      const stereo = PcmAudioFormat(sampleRate: 16000, numChannels: 2);
      final harness = await _Harness.start(format: stereo);

      harness.input.emit([1, 2, 3, 4, 5, 6]);
      harness.input.emit([7, 8]);
      await harness.session.stop();

      final frames = await harness.frames;
      for (final frame in frames) {
        expect(frame.bytes.length.remainder(stereo.bytesPerFrame), 0);
      }
      expect(_flatten(frames), [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('a buffer shorter than one frame produces no frame at all', () async {
      const stereo = PcmAudioFormat(sampleRate: 16000, numChannels: 2);
      final harness = await _Harness.start(format: stereo);

      harness.input.emit([1, 2]);
      await pumpEventQueue();

      expect(harness.received, isEmpty);

      harness.input.emit([3, 4]);
      await harness.session.stop();

      expect(_flatten(await harness.frames), [1, 2, 3, 4]);
    });
  });

  group('the backlog bound', () {
    test('audio captured before the first listen reaches that listener', () async {
      // The plugin's own stream discards every buffer that arrives with no
      // listener, so this is a property of the session rather than of the input.
      final input = _ScriptedAudioInput();
      final capture = MicCapture(input: input);
      final session = ((await capture.start()) as MicCaptureStarted).session;

      input.emit([1, 2, 3, 4]);
      await pumpEventQueue();

      final frames = <MicFrame>[];
      final done = session.frames
          .listen(frames.add)
          .asFuture<void>()
          .timeout(_faultDeadline);
      await pumpEventQueue();

      // Asserted **before** `stop`, and that is the whole point of the shape of
      // this test. `stop` pumps too, so a version that only checked after
      // stopping passed with the controller's `onListen` callback removed — the
      // audio arrived, just not until the capture ended. Subscribing is what has
      // to deliver it, because during a live capture the alternative is waiting
      // for the next buffer.
      expect(_flatten(frames), [1, 2, 3, 4]);

      await session.stop();
      await done;
      expect(session.droppedByteCount, 0);
    });

    test('the bound applies before anyone has listened at all', () async {
      // The property `frames`' docstring advertises — "Buffers up to the backlog
      // bound while nothing is listening" — and the one sold as the OOM defence for
      // an app already at 1.67GB RSS. Worth binding on its own account.
      //
      // It is **not** what kills the `hasListener` mutation, and saying so is the
      // point of this comment. Review finding R0-F4 attributed that mutation's
      // survival to this case, on the reasoning that with no listener the backlog
      // would drain into the controller's unbounded pending-event buffer. Measured,
      // that is not what happens: a single-subscription `StreamController` reports
      // `isPaused == true` before any `listen`, so `!isPaused` already blocks the
      // loop and the bound holds either way. The clause earns its place in a
      // different state — see *audio dropped after the consumer cancels is still
      // reported* below.
      final input = _ScriptedAudioInput();
      final capture = MicCapture(
        input: input,
        // 32 bytes — one millisecond of 16 kHz mono.
        maxBacklog: const Duration(milliseconds: 1),
      );
      final session = ((await capture.start()) as MicCaptureStarted).session;

      // Nobody has listened. Offer four times the bound.
      for (var buffer = 0; buffer < 4; buffer++) {
        input.emit(List.filled(32, buffer));
      }
      await pumpEventQueue();

      expect(
        session.droppedByteCount,
        greaterThan(0),
        reason:
            'the ceiling has to hold with no listener attached, or it is not '
            'a ceiling — it is a promise kept only while someone is watching',
      );
      expect(
        session.droppedByteCount,
        96,
        reason: '4 x 32B against a 32B bound',
      );

      final frames = <MicFrame>[];
      final done = session.frames
          .listen(frames.add)
          .asFuture<void>()
          .timeout(_faultDeadline);
      await session.stop();
      await done;

      expect(
        _flatten(frames),
        List.filled(32, 3),
        reason:
            'and what survives is the newest audio, as when a consumer stalls',
      );
    });

    test('audio dropped after the consumer cancels is still reported', () async {
      // What actually binds `_pump`'s `hasListener` clause, and the corrected
      // mechanism for review finding R0-F4. Measured on a single-subscription
      // `StreamController`:
      //
      //   before any listen : hasListener=false isPaused=true
      //   while listening   : hasListener=true  isPaused=false
      //   while paused      : hasListener=true  isPaused=true
      //   after cancel      : hasListener=false isPaused=false
      //
      // The last row is the gap. After a cancel `isPaused` goes back to false while
      // there is no subscriber, so without `hasListener` the loop runs and every
      // frame is handed to `_controller.add` — which, on a single-subscription
      // controller that can never be listened to again, buffers it forever. Two
      // consequences, both of which this class exists to prevent: the backlog's
      // ceiling stops applying (the bytes accumulate in the controller instead), and
      // `droppedByteCount` reports **0** while audio is in fact being discarded.
      // Silent loss reported as no loss.
      final input = _ScriptedAudioInput();
      final capture = MicCapture(
        input: input,
        maxBacklog: const Duration(milliseconds: 1),
      );
      final session = ((await capture.start()) as MicCaptureStarted).session;

      final subscription = session.frames.listen((_) {});
      await pumpEventQueue();
      await subscription.cancel();

      for (var buffer = 0; buffer < 4; buffer++) {
        input.emit(List.filled(32, buffer));
      }
      await pumpEventQueue();

      expect(
        session.droppedByteCount,
        96,
        reason:
            'a cancelled consumer is not a consumer: the ceiling still applies '
            'and what it discards is still counted',
      );
    });

    test('a stalled consumer loses the oldest audio, not the newest', () async {
      final harness = await _Harness.start(
        // 32 bytes — one millisecond of 16 kHz mono.
        maxBacklog: const Duration(milliseconds: 1),
        listen: false,
      );
      final frames = <MicFrame>[];
      final subscription = harness.session.frames.listen(frames.add);
      await pumpEventQueue();

      subscription.pause();
      for (var buffer = 0; buffer < 4; buffer++) {
        harness.input.emit(List.filled(16, buffer));
      }
      await pumpEventQueue();
      subscription.resume();
      await pumpEventQueue();
      await harness.session.stop();
      await subscription.asFuture<void>().timeout(_faultDeadline);

      expect(
        harness.session.droppedByteCount,
        32,
        reason:
            'a 32-byte bound holds two 16-byte buffers, so of the four offered '
            'exactly two are dropped',
      );
      expect(
        _flatten(frames),
        List.filled(16, 2) + List.filled(16, 3),
        reason:
            'buffers 0 and 1 are the ones dropped; the recogniser resumes at '
            'the present moment rather than accumulating lag it can never pay '
            'off',
      );
    });

    test('the gap is attached to the frame that follows it', () async {
      final harness = await _Harness.start(
        maxBacklog: const Duration(milliseconds: 1),
        listen: false,
      );
      final frames = <MicFrame>[];
      final subscription = harness.session.frames.listen(frames.add);
      await pumpEventQueue();

      subscription.pause();
      // Three buffers dropped in one stall must arrive as one 48-byte gap on the
      // next frame, not as three separate losses nobody can add up.
      for (var buffer = 0; buffer < 5; buffer++) {
        harness.input.emit(List.filled(16, buffer));
      }
      await pumpEventQueue();
      subscription.resume();
      await pumpEventQueue();
      await harness.session.stop();
      await subscription.asFuture<void>().timeout(_faultDeadline);

      expect(frames.first.precedingGapBytes, 48);
      expect(frames.first.followsGap, isTrue);
      expect(
        frames.skip(1).every((frame) => frame.precedingGapBytes == 0),
        isTrue,
        reason: 'the gap is reported once, on the frame after it',
      );
      expect(harness.session.droppedByteCount, 48);
    });

    test('a bound smaller than one buffer keeps the newest buffer', () async {
      // Degenerate but reachable: a platform buffer larger than the whole bound.
      // Dropping until the backlog fits would empty it completely and the capture
      // would deliver nothing, forever.
      final harness = await _Harness.start(
        maxBacklog: const Duration(milliseconds: 1),
        listen: false,
      );
      final frames = <MicFrame>[];
      final subscription = harness.session.frames.listen(frames.add);
      await pumpEventQueue();

      subscription.pause();
      harness.input.emit(List.filled(64, 7));
      harness.input.emit(List.filled(64, 9));
      await pumpEventQueue();
      subscription.resume();
      await pumpEventQueue();
      await harness.session.stop();
      await subscription.asFuture<void>().timeout(_faultDeadline);

      expect(_flatten(frames), List.filled(64, 9));
      expect(harness.session.droppedByteCount, 64);
    });

    test('a consumer that keeps up loses nothing', () async {
      final harness = await _Harness.start(
        maxBacklog: const Duration(milliseconds: 1),
      );

      for (var buffer = 0; buffer < 20; buffer++) {
        harness.input.emit(List.filled(16, buffer));
        await pumpEventQueue();
      }
      await harness.session.stop();

      expect(await harness.frames, hasLength(20));
      expect(harness.session.droppedByteCount, 0);
    });
  });

  group('lifecycle', () {
    test('stop drains the audio, then closes the stream', () async {
      final harness = await _Harness.start();

      harness.input.emit([1, 2]);
      harness.input.emit([3, 4]);
      await harness.session.stop();

      // The `frames` future completing at all is the closure; the content is the
      // drain. Task 2.2 depends on both: `SttEngine.transcribe` consumes the
      // stream and cannot emit a final transcript until it ends.
      expect(_flatten(await harness.frames), [1, 2, 3, 4]);
      expect(harness.session.isCapturing, isFalse);
      expect(harness.input.stopCalls, 1);
    });

    test('stop is prompt when the plugin closes its stream', () async {
      // Review finding R0-F5. Deleting the `_rawClosed.complete()` in `onDone`
      // left all 51 tests green — including the grace-period test below, which
      // asserts `elapsed >= drainGrace` and therefore passes *more* easily when
      // every stop waits the full 250ms. Nothing asserted that the normal case is
      // fast. On a dictation UI a quarter-second added to the end of every
      // utterance is perceptible, and the whole argument for `drainGrace`'s value
      // is that the close "is already in flight" — which only holds if something
      // notices it.
      final harness = await _Harness.start();

      harness.input.emit([1, 2]);
      await pumpEventQueue();
      final stopwatch = Stopwatch()..start();
      await harness.session.stop();
      stopwatch.stop();

      expect(
        stopwatch.elapsed,
        lessThan(MicCaptureSession.drainGrace ~/ 5),
        reason:
            'a plugin that closes its stream must not be waited out; '
            'measured ${stopwatch.elapsedMilliseconds}ms against a '
            '${MicCaptureSession.drainGrace.inMilliseconds}ms grace',
      );
      expect(_flatten(await harness.frames), [1, 2]);
    });

    test('stop is idempotent and releases the input once', () async {
      final harness = await _Harness.start();

      await harness.session.stop();
      await harness.session.stop();
      await harness.session.stop();

      expect(harness.input.stopCalls, 1);
      await harness.frames;
    });

    test('a second start is refused while one is running', () async {
      final input = _ScriptedAudioInput();
      final capture = MicCapture(input: input);
      final first = ((await capture.start()) as MicCaptureStarted).session;

      final second = await capture.start();

      expect(second, isA<MicCaptureBusy>());
      expect(
        input.startStreamCalls,
        1,
        reason:
            "the plugin's own answer to a second startStream is to close the "
            'first stream with no error — the outcome this refusal prevents',
      );

      // And the running capture is genuinely untouched.
      final frames = <MicFrame>[];
      final done = first.frames
          .listen(frames.add)
          .asFuture<void>()
          .timeout(_faultDeadline);
      input.emit([1, 2]);
      await first.stop();
      await done;
      expect(_flatten(frames), [1, 2]);
    });

    test('a start after a stop waits for the recorder to come back', () async {
      // `isCapturing` goes false at the top of `stop()`, before the plugin has
      // released anything. Starting on that signal alone overlaps two streams on
      // one recorder, which is the same hazard `MicCaptureBusy` covers.
      final input = _ScriptedAudioInput();
      final capture = MicCapture(input: input);
      final first = ((await capture.start()) as MicCaptureStarted).session;

      final gate = Completer<void>();
      input.releaseGate = gate;
      final stopping = first.stop();
      await pumpEventQueue();

      var restarted = false;
      final restarting = capture.start().then((_) => restarted = true);
      await pumpEventQueue();

      expect(
        restarted,
        isFalse,
        reason: 'the release has not completed, so no second stream may open',
      );
      expect(input.startStreamCalls, 1);

      gate.complete();
      await stopping;
      await restarting;

      expect(input.startStreamCalls, 2);
    });

    test('the format watcher is registered before the stream opens', () async {
      // Review finding R1-F3: this ordering was documented as load-bearing in the
      // round that introduced the comment, and swapping the two statements left all
      // 73 tests green — a documented invariant with no guard, which is what R0-F7
      // was. On Android `notifyConfigChanged` fires immediately after the platform
      // call `startStream` awaits resolves, so a watcher registered afterwards can
      // miss the only notification there will be.
      final input = _ScriptedAudioInput();
      final capture = MicCapture(input: input);

      await capture.start();

      expect(
        input.calls,
        ['hasPermission', 'watchFormat', 'startStream'],
        reason: 'permission first, then the watcher, then the microphone',
      );
    });

    test('the session getter tracks the running capture', () async {
      // Review finding R1-F4. This getter was touched by no test: I had claimed it
      // was "covered incidentally by the busy path", and it is not — that path reads
      // the `_session` field directly and never the getter. Reducing it to
      // `return _session;` left all 73 green.
      final input = _ScriptedAudioInput();
      final capture = MicCapture(input: input);

      expect(capture.session, isNull, reason: 'nothing started yet');

      final started = (await capture.start()) as MicCaptureStarted;
      expect(capture.session, same(started.session));

      await started.session.stop();
      expect(
        capture.session,
        isNull,
        reason:
            'a stopped session is not a running capture, which is the whole '
            'distinction the getter draws over the field',
      );
    });

    test('dispose stops the capture and releases the recorder', () async {
      final harness = await _Harness.start();

      await harness.capture.dispose();

      expect(harness.input.stopCalls, 1);
      expect(harness.input.disposeCalls, 1);
      expect(harness.session.isCapturing, isFalse);
      await harness.frames;
    });

    test('audio queued behind a paused consumer survives stop', () async {
      // The drain has to reach a consumer that is *still* paused when the capture
      // ends — otherwise the tail of the utterance waits for a resume that
      // arrives after the stream was already closed out, and the recogniser never
      // sees the last words.
      final harness = await _Harness.start(listen: false);
      final frames = <MicFrame>[];
      final subscription = harness.session.frames.listen(frames.add);
      await pumpEventQueue();

      subscription.pause();
      harness.input.emit([1, 2]);
      harness.input.emit([3, 4]);
      await pumpEventQueue();
      await harness.session.stop();

      expect(frames, isEmpty, reason: 'still paused, so nothing delivered yet');

      subscription.resume();
      await subscription.asFuture<void>().timeout(_faultDeadline);

      expect(_flatten(frames), [1, 2, 3, 4]);
    });

    test('a plugin that never closes its stream does not hang stop', () async {
      // The drain waits for the plugin's stream close. If that close never comes,
      // an unbounded wait would freeze whatever tapped "stop" — Task 1.11's
      // lesson, that a seam which hangs reports nothing and a frozen UI reads as
      // a crash. Bound instead, and the audio already captured still goes out.
      final input = _ScriptedAudioInput()..closesStreamOnStop = false;
      final capture = MicCapture(input: input);
      final session = ((await capture.start()) as MicCaptureStarted).session;
      final frames = <MicFrame>[];
      final drained = session.frames
          .listen(frames.add)
          .asFuture<void>()
          .timeout(_faultDeadline);

      input.emit([1, 2]);
      await pumpEventQueue();
      final stopwatch = Stopwatch()..start();
      await session.stop();
      stopwatch.stop();
      await drained;

      expect(_flatten(frames), [1, 2]);
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(MicCaptureSession.drainGrace),
        reason: 'the grace period is what was waited out',
      );
      expect(
        stopwatch.elapsed,
        lessThan(MicCaptureSession.drainGrace * 8),
        reason: 'and it is a bound, not an open-ended wait',
      );
    });

    test(
      'a failure releasing the microphone is reported, not swallowed',
      () async {
        // "the microphone may still be open" is not something to lose. The stream
        // is still closed out first, so a consumer is not left hanging either.
        final harness = await _Harness.start();
        harness.input.stopError = StateError('the recorder refused to stop');

        await expectLater(harness.session.stop(), throwsStateError);

        expect(harness.session.isCapturing, isFalse);
        await harness.frames;
      },
    );

    test('dispose with no capture still releases the recorder', () async {
      final input = _ScriptedAudioInput();
      final capture = MicCapture(input: input);

      await capture.dispose();

      expect(input.disposeCalls, 1);
      expect(input.stopCalls, 0);
    });
  });

  group('faults', () {
    test('a microphone error arrives after the audio it interrupted', () async {
      // Order matters: a half-utterance is still transcribable, so the audio goes
      // out first and the reason it ended goes out second.
      final harness = await _Harness.start(listen: false);
      final events = <Object>[];
      final done = Completer<void>();
      harness.session.frames.listen(
        events.add,
        onError: events.add,
        onDone: done.complete,
      );

      harness.input.emit([1, 2]);
      harness.input.emitError(StateError('audio route lost'));
      await done.future.timeout(_faultDeadline);

      expect(events, hasLength(2));
      expect((events.first as MicFrame).bytes, [1, 2]);
      expect(events.last, isA<MicCaptureFault>());
      expect((events.last as MicCaptureFault).message, contains('route lost'));
      expect(
        harness.input.stopCalls,
        1,
        reason: 'a fault must still hand the microphone back',
      );
      expect(harness.session.isCapturing, isFalse);
    });

    test('the platform ending the stream by itself is a fault', () async {
      // Only `stop` produces a normal end. The stream closing on its own is the
      // microphone going away — a revoked permission, a route change, another app
      // taking the input — and the alternative to reporting it is a transcript
      // that just stops.
      final harness = await _Harness.start(listen: false);
      Object? error;
      final done = Completer<void>();
      harness.session.frames.listen(
        (_) {},
        onError: (Object e) => error = e,
        onDone: done.complete,
      );

      await harness.input.closeRaw();
      await done.future.timeout(_faultDeadline);

      expect(error, isA<MicCaptureFault>());
      expect((error! as MicCaptureFault).message, contains('unexpectedly'));
    });

    test('a format the platform substituted stops the capture', () async {
      // 16-bit PCM at the wrong sample rate does not fail — it transcribes as
      // nonsense. A capture that cannot be trusted is worse than no capture, so
      // this is the one condition that ends a session that is otherwise healthy.
      final harness = await _Harness.start(listen: false);
      Object? error;
      final done = Completer<void>();
      harness.session.frames.listen(
        (_) {},
        onError: (Object e) => error = e,
        onDone: done.complete,
      );

      harness.input.coerceFormat('48000Hz rather than 16000Hz');
      await done.future.timeout(_faultDeadline);

      expect(error, isA<MicCaptureFault>());
      expect((error! as MicCaptureFault).message, contains('48000Hz'));
      expect(harness.input.stopCalls, 1);
    });

    test('a fault does not discard audio the consumer has not read yet', () async {
      // The fault is queued behind the audio rather than delivered in place of
      // it. That only has teeth when there *is* audio still queued — which is
      // why this test pauses first: with the consumer keeping up, every frame has
      // already been delivered by the time the error lands, and the ordering rule
      // is never exercised. The mutation deleting the guard survived 50 tests
      // until this one existed.
      final harness = await _Harness.start(listen: false);
      final events = <Object>[];
      final done = Completer<void>();
      final subscription = harness.session.frames.listen(
        events.add,
        onError: events.add,
        onDone: done.complete,
      );
      await pumpEventQueue();

      subscription.pause();
      harness.input.emit([1, 2]);
      harness.input.emit([3, 4]);
      await pumpEventQueue();
      harness.input.emitError(StateError('route lost'));
      await pumpEventQueue();
      subscription.resume();
      await done.future.timeout(_faultDeadline);

      expect(
        _flatten(events.whereType<MicFrame>()),
        [1, 2, 3, 4],
        reason:
            'the utterance captured before the microphone died is still '
            'transcribable, and is the more useful half of this event',
      );
      expect(events.last, isA<MicCaptureFault>());
    });

    test('a fault is reported once, and stop after it is a no-op', () async {
      final harness = await _Harness.start(listen: false);
      final errors = <Object>[];
      final done = Completer<void>();
      harness.session.frames.listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );

      harness.input.emitError(StateError('first'));
      await done.future.timeout(_faultDeadline);
      await harness.session.stop();

      expect(errors, hasLength(1));
      expect(harness.input.stopCalls, 1);
    });

    test('buffers arriving after a fault are ignored', () async {
      final harness = await _Harness.start(listen: false);
      final events = <Object>[];
      final done = Completer<void>();
      harness.session.frames.listen(
        events.add,
        onError: events.add,
        onDone: done.complete,
      );

      harness.input.emitError(StateError('lost'));
      harness.input.emit([9, 9]);
      await done.future.timeout(_faultDeadline);

      expect(events.whereType<MicFrame>(), isEmpty);
    });
  });

  group('the stall watchdog', () {
    // Review findings R0-F1/R0-F2. This is the *only* "the microphone went away"
    // condition either real platform produces. `record` registers no `onDone` on
    // the platform stream and neither native side ever ends its event channel, so
    // a stream that closes by itself is not a thing; what iOS actually does on an
    // audio-session interruption is pause the engine and never resume it, leaving
    // the tap installed and the buffers simply absent. Before this timer existed
    // that state was invisible: the session stayed `isCapturing` with `frames`
    // open forever, and `SttEngine.transcribe` consumes `frames` to completion —
    // so a call mid-dictation meant a transcript that never arrived.
    test('faults when the microphone goes silent', () async {
      final harness = await _Harness.start(
        stallTimeout: const Duration(milliseconds: 60),
        listen: false,
      );
      // Asserted with a *non-default* value on purpose. The sibling test above
      // reads the same accessor with the 5s default, so a `configuredStallTimeout`
      // that ignored `_stallTimeout` and returned a hardcoded 5s would satisfy it —
      // a test-only accessor that lies about the thing it exists to expose. Found
      // by mutation immediately after adding the accessor, which makes it the
      // fourth instance in this task of a line written in a fixing round with
      // nothing holding it.
      expect(
        harness.session.configuredStallTimeout,
        const Duration(milliseconds: 60),
      );
      final events = <Object>[];
      final done = Completer<void>();
      harness.session.frames.listen(
        events.add,
        onError: events.add,
        onDone: done.complete,
      );

      harness.input.emit([1, 2]);
      await done.future.timeout(_faultDeadline);

      expect(
        _flatten(events.whereType<MicFrame>()),
        [1, 2],
        reason:
            'the audio captured before the input died is still '
            'transcribable and still goes out first',
      );
      expect(events.last, isA<MicCaptureFault>());
      expect(
        (events.last as MicCaptureFault).message,
        contains('no audio for'),
      );
      expect(harness.session.isCapturing, isFalse);
      expect(
        harness.input.stopCalls,
        1,
        reason: 'a stall must still hand the microphone back',
      );
    });

    test('it is on by default, at five seconds', () async {
      // Review finding R1-F1. Two mutations survived all 73 tests: deleting the
      // default outright (making it `null`, i.e. the watchdog off everywhere) and
      // changing it to 500 seconds. Neither is observable, because `_Harness`
      // deliberately opts out with `null` and every watchdog test passes an explicit
      // duration — so no test ever constructed a `MicCapture` with the watchdog on
      // by default. The entire R0-F2 remedy could have been disabled in production
      // with a green suite, which is R0-F7's shape on the feature R0-F2 asked for.
      expect(
        MicCapture(input: _ScriptedAudioInput()).stallTimeout,
        const Duration(seconds: 5),
      );
    });

    test('the default reaches the session, not just the field', () async {
      // The composition the value assertion above cannot make on its own: that the
      // constructor's default is what the session actually runs with.
      //
      // This replaces a test that waited out the real five seconds. Round 2 of
      // review measured that one's marginal mutation coverage and found it **zero**
      // — every edit either party constructed, including breaking this exact
      // plumbing while leaving `MicCapture.stallTimeout` correct, is killed by the
      // value assertion together with the millisecond-scale tests below. Five
      // seconds on every CI run for coverage that was already there is not a trade
      // worth making, and the reviewer had run the suite forty-six times to find
      // that out.
      final input = _ScriptedAudioInput();
      final capture = MicCapture(input: input);

      final session = ((await capture.start()) as MicCaptureStarted).session;

      expect(session.configuredStallTimeout, const Duration(seconds: 5));
      await session.stop();
    });

    test('a capture that never receives a single buffer still faults', () async {
      // Review finding R1-F2, and the worst form of the failure the watchdog exists
      // for: a microphone that produced nothing at all. Deleting the arm in
      // `_attach` left all 73 tests green, because every other watchdog test emits a
      // buffer first and `_onRawBuffer` re-arms — so what they bound was the
      // *re*-arm. This case is reachable on both platforms: on iOS an interruption
      // beginning between `engine.start()` and the first tap callback leaves
      // `m_isPaused` true and `handleTap` returns early forever; on Android a
      // `PCMReader.read()` that keeps returning 0 is filtered before the sink, so no
      // event is ever sent.
      final harness = await _Harness.start(
        stallTimeout: const Duration(milliseconds: 60),
        listen: false,
      );
      Object? fault;
      final done = Completer<void>();
      harness.session.frames.listen(
        (_) {},
        onError: (Object error) => fault = error,
        onDone: done.complete,
      );

      // Nothing emitted at all. Bounded so a broken watchdog fails in seconds
      // rather than hanging to `flutter_test`'s 30s default — raised in review
      // round 2, where three mutation rows spent most of their wall clock here.
      await done.future.timeout(_faultDeadline);

      expect(fault, isA<MicCaptureFault>());
      expect(harness.input.stopCalls, 1);
    });

    test('a live microphone keeps re-arming it', () async {
      // The watchdog measures *buffers*, not speech. Any live input produces
      // buffers continuously — a quiet room is near-zero samples, not an absence —
      // so this must not fire while audio is flowing, however quiet.
      final harness = await _Harness.start(
        stallTimeout: const Duration(milliseconds: 100),
      );

      for (var i = 0; i < 6; i++) {
        harness.input.emit([0, 0]);
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(harness.session.isCapturing, isTrue);

      await harness.session.stop();
      expect(_flatten(await harness.frames), List.filled(12, 0));
    });

    test('an empty buffer is proof of life too', () async {
      // Re-armed before the whole-frame check, deliberately: a buffer carrying no
      // whole frame still means the input is alive, and iOS does emit those.
      final harness = await _Harness.start(
        stallTimeout: const Duration(milliseconds: 100),
      );

      for (var i = 0; i < 6; i++) {
        harness.input.emit([]);
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      expect(harness.session.isCapturing, isTrue);
      await harness.session.stop();
    });

    test('it does not fire after a normal stop', () async {
      // A cancelled timer, or a fault delivered onto a closed stream, would both
      // show up here.
      final harness = await _Harness.start(
        stallTimeout: const Duration(milliseconds: 40),
      );

      harness.input.emit([1, 2]);
      await harness.session.stop();
      final frames = await harness.frames;
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(_flatten(frames), [1, 2]);
      expect(harness.input.stopCalls, 1);
    });

    test('it can be disabled', () async {
      // Off is a legitimate configuration — a caller driving a finite, scripted
      // input has no stall to detect.
      final harness = await _Harness.start(stallTimeout: null);

      harness.input.emit([1, 2]);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(harness.session.isCapturing, isTrue);
      await harness.session.stop();
      expect(_flatten(await harness.frames), [1, 2]);
    });
  });

  group('RecordAudioInput.describeFormatMismatch', () {
    // The plugin fires `onConfigChanged` when *any* of bit rate, sample rate or
    // channel count was adjusted. Bit rate does not exist for a raw PCM stream —
    // neither platform's PCM encoder reads it — so this decision is what keeps
    // the tripwire from ending a perfectly good capture.
    String? describe({
      AudioEncoder encoder = AudioEncoder.pcm16bits,
      int sampleRate = 16000,
      int numChannels = 1,
    }) => RecordAudioInput.describeFormatMismatch(
      requested: PcmAudioFormat.sttMono16k,
      encoder: encoder,
      sampleRate: sampleRate,
      numChannels: numChannels,
    );

    test('the requested format is not a mismatch', () {
      expect(describe(), isNull);
    });

    test('an adjustment to nothing that matters is not a mismatch', () {
      // This *is* the bit-rate case: the callback fired, and all three fields the
      // PCM contract depends on still match. Faulting here would make the
      // tripwire worse than not watching at all.
      expect(
        describe(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
        isNull,
      );
    });

    test('a substituted sample rate is named, with both values', () {
      expect(describe(sampleRate: 48000), '48000Hz rather than 16000Hz');
    });

    test('a substituted channel count is named', () {
      expect(describe(numChannels: 2), '2 channels rather than 1');
    });

    test('a substituted encoder is named', () {
      // The one that produces garbage rather than wrong-speed audio: `aacLc` is
      // `RecordConfig`'s default, and encoded frames handed to a PCM recogniser
      // are noise.
      expect(describe(encoder: AudioEncoder.aacLc), 'encoder aacLc');
    });

    test('every difference is reported, not just the first', () {
      expect(
        describe(
          encoder: AudioEncoder.aacLc,
          sampleRate: 44100,
          numChannels: 2,
        ),
        'encoder aacLc, 44100Hz rather than 16000Hz, 2 channels rather than 1',
      );
    });
  });
}

/// A started capture plus the pieces a test needs to drive and read it.
class _Harness {
  _Harness._({
    required this.capture,
    required this.input,
    required this.session,
    required this.received,
    required this._drained,
  });

  /// [stallTimeout] defaults to `null` — off — so a test that is not about the
  /// watchdog leaves no timer running and cannot be made flaky by one.
  static Future<_Harness> start({
    PcmAudioFormat format = PcmAudioFormat.sttMono16k,
    Duration maxBacklog = const Duration(seconds: 2),
    Duration? stallTimeout,
    bool listen = true,
  }) async {
    final input = _ScriptedAudioInput();
    final capture = MicCapture(
      input: input,
      format: format,
      maxBacklog: maxBacklog,
      stallTimeout: stallTimeout,
    );
    final started = await capture.start();
    final session = (started as MicCaptureStarted).session;

    final received = <MicFrame>[];
    Future<void>? drained;
    if (listen) {
      drained = session.frames
          .listen(received.add)
          .asFuture<void>()
          .timeout(_faultDeadline);
    }
    return _Harness._(
      capture: capture,
      input: input,
      session: session,
      received: received,
      drained: drained,
    );
  }

  final MicCapture capture;
  final _ScriptedAudioInput input;
  final MicCaptureSession session;

  /// Frames delivered so far, when the harness is listening.
  final List<MicFrame> received;

  final Future<void>? _drained;

  /// Every frame delivered, once the stream has closed.
  Future<List<MicFrame>> get frames async {
    await _drained;
    return received;
  }

  /// The bytes of each delivered frame, once the stream has closed.
  Future<List<List<int>>> get byteRuns async =>
      (await frames).map((frame) => frame.bytes.toList()).toList();
}

/// An [AudioInput] a test drives directly.
///
/// The raw stream is a broadcast controller with no backpressure, matching what
/// `record` 7.1.1 returns.
class _ScriptedAudioInput implements AudioInput {
  _ScriptedAudioInput({this.permission = true});

  /// What [hasPermission] answers.
  bool permission;

  /// Thrown by [hasPermission] instead of answering.
  Object? permissionError;

  /// Thrown by [startStream] instead of opening.
  Object? startError;

  /// Thrown by [stop] after the call has been counted.
  Object? stopError;

  /// Whether [stop] closes the raw stream, as `record` does. Cleared to model a
  /// plugin that leaves it open.
  bool closesStreamOnStop = true;

  /// Held open to keep [stop] pending, so a test can observe the window between
  /// a capture ending and the recorder actually coming back.
  Completer<void>? releaseGate;

  int startStreamCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  PcmAudioFormat? requestedFormat;

  /// Every seam method called, in order. Exists for the registration-order test:
  /// counts cannot express a sequence.
  final List<String> calls = <String>[];

  final StreamController<Uint8List> _raw =
      StreamController<Uint8List>.broadcast();
  void Function(String description)? _onCoerced;

  void emit(List<int> bytes) => _raw.add(Uint8List.fromList(bytes));

  void emitError(Object error) => _raw.addError(error);

  Future<void> closeRaw() => _raw.close();

  /// Fires the platform's "I substituted your format" callback.
  void coerceFormat(String description) => _onCoerced!(description);

  @override
  Future<bool> hasPermission({bool request = true}) async {
    calls.add('hasPermission');
    final error = permissionError;
    if (error != null) throw error;
    return permission;
  }

  @override
  Future<Stream<Uint8List>> startStream(PcmAudioFormat format) async {
    calls.add('startStream');
    final error = startError;
    if (error != null) throw error;
    startStreamCalls++;
    requestedFormat = format;
    return _raw.stream;
  }

  @override
  Future<void> watchFormat(void Function(String description) onCoerced) async {
    calls.add('watchFormat');
    _onCoerced = onCoerced;
  }

  /// Mirrors `record` 7.1.1: stopping closes the record stream
  /// (`AudioRecorder.stop` → `_stopRecordStream`), which is what lets a session's
  /// drain be complete rather than best-effort.
  @override
  Future<void> stop() async {
    stopCalls++;
    final gate = releaseGate;
    if (gate != null) await gate.future;
    final error = stopError;
    if (error != null) throw error;
    if (closesStreamOnStop && !_raw.isClosed) await _raw.close();
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (!_raw.isClosed) await _raw.close();
  }
}

/// A bound on every wait in this file that a broken `MicCapture` could hang: the
/// eight waits for a fault, and the nine subscription drains that every
/// `await harness.frames` resolves through.
///
/// A test that expects a `MicCaptureFault` and does not get one must fail in
/// seconds rather than hang to `flutter_test`'s 30s default. Review finding R3-F1:
/// I reported bounding two such waits and had bounded one, and the consequence was
/// measurable — the reviewer's row that broke the fault path spent most of its wall
/// clock in the wait I had missed. Named once here so the next one cannot drift, and
/// so `grep` over this file answers "are they all bounded?" with a single count.
///
/// The drains came second, and the sentence that reached for them came before they
/// did: this doc said "every wait for a fault **or a stream close**" while the
/// close waits were still unbounded — flagged in review round 4 as a non-blocking
/// note, and fixed by making the claim true rather than by narrowing it, because
/// the residue was worth removing. It is what made this file's worst-case mutation
/// row cost minutes: an edit that stops the stream ever closing left thirteen
/// drains waiting 30s each.
///
/// Bounding at subscription rather than at the await is deliberate and is not a
/// shortcut — a stream that has not closed this long after being listened to *is*
/// the failure, whenever the test gets round to awaiting it.
const _faultDeadline = Duration(seconds: 5);

List<int> _flatten(Iterable<MicFrame> frames) =>
    frames.expand((frame) => frame.bytes).toList();
