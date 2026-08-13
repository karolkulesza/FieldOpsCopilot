import 'dart:typed_data';

import 'package:field_ops_copilot/services/audio/stt_config.dart';
import 'package:field_ops_copilot/services/audio/stt_isolate_worker.dart';
import 'package:field_ops_copilot/services/audio/stt_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// The only suite that spawns the **real** STT isolate.
///
/// It cannot build a recogniser — a host test runner has neither the 43MB model
/// nor, on most CI images, the native library — and that is what makes it useful:
/// it drives the failure path end to end through a real `Isolate.spawn`, the real
/// handshake and the real `onExit`/`onError` wiring, none of which
/// `stt_worker_test.dart` touches because that one calls `serveSttRequests`
/// directly.
///
/// The failure *reason* is deliberately not asserted. It differs by environment —
/// a missing dylib on Linux CI, a missing framework on macOS, four nonexistent
/// paths everywhere — and pinning it would make this a test of the environment
/// rather than of the host. `isolate_inference_host_test.dart` states the same
/// exclusion for the same reason.
void main() {
  final config = SttConfig.forInstallDirectory(
    '/nonexistent/fieldops-test-stt',
  );

  test(
    'a load that cannot succeed fails, and leaves the host retryable',
    () async {
      final host = IsolateSttHost(shutdownGrace: const Duration(seconds: 2));
      addTearDown(host.shutdown);

      await expectLater(
        host.start(config),
        throwsA(isA<SttFailure>()),
        reason: 'a failed load must be reported, not hang or leak a StateError',
      );
      expect(host.isRunning, isFalse);

      // The retry: it has to get as far as failing *again* for the same reason,
      // rather than being refused because the host declared itself finished. The
      // inference host shipped that bug once — a failed start torn down with
      // `shutdown()` — and it made one transient load failure permanent.
      await expectLater(
        host.start(config),
        throwsA(isA<SttFailure>()),
        reason: 'the host must accept a second attempt after a failed load',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a failed load reports the recognizer as lost',
    () async {
      // The distinction the caller acts on: `recognizerLost` means "reload", a bare
      // failure means "this session went wrong". A load that never produced a
      // recogniser is unambiguously the former.
      final host = IsolateSttHost(shutdownGrace: const Duration(seconds: 2));
      addTearDown(host.shutdown);

      await expectLater(
        host.start(config),
        throwsA(
          isA<SttFailure>().having(
            (f) => f.recognizerLost,
            'recognizerLost',
            isTrue,
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  group('use before start throws instead of hanging', () {
    test('beginSession', () {
      final host = IsolateSttHost();
      addTearDown(host.shutdown);
      expect(host.beginSession, throwsA(isA<StateError>()));
    });

    test('acceptAudio', () {
      final host = IsolateSttHost();
      addTearDown(host.shutdown);
      expect(
        () => host.acceptAudio(SttAudioRequest(bytes: Uint8List(2))),
        throwsA(isA<StateError>()),
      );
    });

    test('finishSession', () {
      final host = IsolateSttHost();
      addTearDown(host.shutdown);
      expect(host.finishSession, throwsA(isA<StateError>()));
    });

    test('cancelSession', () {
      final host = IsolateSttHost();
      addTearDown(host.shutdown);
      expect(host.cancelSession, throwsA(isA<StateError>()));
    });
  });

  test('shutdown on a host that never started is a no-op', () async {
    // Riverpod's `onDispose` fires whether or not anything ever initialised the
    // engine, so this is a real path rather than a defensive nicety.
    final host = IsolateSttHost();
    await expectLater(host.shutdown(), completes);
  });

  test('shutdown is idempotent', () async {
    final host = IsolateSttHost();
    await host.shutdown();
    await expectLater(host.shutdown(), completes);
  });

  test('start after shutdown is refused', () async {
    // The opposite of the retry case above, and the reason the two teardown paths
    // are distinct: an explicit shutdown means the caller is holding a stale
    // engine, and quietly reviving it would hide that.
    final host = IsolateSttHost();
    await host.shutdown();

    await expectLater(host.start(config), throwsA(isA<StateError>()));
  });
}
