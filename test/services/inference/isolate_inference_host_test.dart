import 'package:field_ops_copilot/services/inference/inference_config.dart';
import 'package:field_ops_copilot/services/inference/inference_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

/// The only suite that spawns the **real** inference isolate.
///
/// It cannot load a model — a host test runner has no weights and no native engine —
/// and that is exactly what makes it useful: it drives the failure path end to end
/// through a real `Isolate.spawn`, the real handshake, and the real `onExit`/`onError`
/// wiring. Two things are asserted, both of which were wrong at some point while
/// writing this:
///
/// 1. A load that cannot succeed surfaces as an [InferenceFailure] — not a hang, and
///    not a `StateError` from some later call that assumed the host was up.
/// 2. The host is **still usable afterwards.** The first version tore down a failed
///    start with `shutdown()`, which marks the host finished, so a second attempt
///    threw `StateError('was shut down')`. On device that would make one transient
///    load failure permanent: the engine promises a failed load stays retryable, and
///    that promise is only real if the host underneath it agrees.
///
/// The failure *reason* is deliberately not asserted. It differs by environment — a
/// missing native library on Linux CI, a missing platform channel on macOS, a
/// nonexistent model path everywhere — and pinning it would make this a test of the
/// host's environment rather than of the host.
void main() {
  const config = InferenceConfig(
    modelPath: '/nonexistent/fieldops-test-model.litertlm',
  );

  test(
    'a load that cannot succeed fails, and leaves the host retryable',
    () async {
      final host = IsolateInferenceHost(
        // Short, because nothing here should need a graceful teardown: keeping the
        // default 10s would only slow the failure path down.
        shutdownGrace: const Duration(seconds: 2),
      );
      addTearDown(host.shutdown);

      await expectLater(
        host.start(config),
        throwsA(isA<InferenceFailure>()),
        reason: 'a failed load must be reported, not hang or leak a StateError',
      );
      expect(host.isRunning, isFalse);

      // The retry: it must get as far as failing *again* for the same reason, rather
      // than being refused because the host declared itself finished.
      await expectLater(
        host.start(config),
        throwsA(isA<InferenceFailure>()),
        reason: 'the host must accept a second attempt after a failed load',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('generate before start throws instead of hanging', () {
    final host = IsolateInferenceHost();
    addTearDown(host.shutdown);

    expect(() => host.generate(prompt: 'E-102'), throwsA(isA<StateError>()));
  });

  test('shutdown on a host that never started is a no-op', () async {
    // Riverpod's `onDispose` fires whether or not anything ever initialised the
    // engine, so this is a real path rather than a defensive nicety.
    final host = IsolateInferenceHost();
    await expectLater(host.shutdown(), completes);
  });

  test('start after shutdown is refused', () async {
    // The opposite of the retry case above, and the reason the two teardown paths are
    // distinct: an explicit shutdown means the caller is holding a stale engine, and
    // quietly reviving it would hide that.
    final host = IsolateInferenceHost();
    await host.shutdown();

    await expectLater(host.start(config), throwsA(isA<StateError>()));
  });
}
