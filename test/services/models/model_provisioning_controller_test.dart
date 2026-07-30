import 'dart:async';
import 'dart:io';

import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_downloader.dart';
import 'package:field_ops_copilot/services/models/model_provisioner.dart';
import 'package:field_ops_copilot/services/models/model_provisioning_controller.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:field_ops_copilot/services/models/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rule under test is the one Task 1.7 wrote down and left unenforced: a
/// **download** that failed its digest must not be retried, because the provisioner
/// will happily transfer the same 2.6GB and fail identically. Everything else here
/// exists to make sure that rule is not applied too widely — a transport failure or a
/// moved pin *must* stay retryable, or a technician in a basement can never recover.
void main() {
  /// `provision()` needs a real directory (it hashes files); the downloader is faked,
  /// so nothing touches the network.
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('provisioning-controller');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// Builds a container whose provisioner serves [body] for every download.
  ///
  /// Wired through the real [ModelProvisioner] rather than a fake one on purpose: the
  /// sticky rule keys off `ModelCorrupt.origin`, and that value is produced by the
  /// provisioner's own logic. A faked provisioner could hand the controller an origin
  /// the real one would never produce, and the test would prove nothing.
  ProviderContainer containerFor({
    required List<int> body,
    required String pinnedHash,
    ModelDownloadException? failure,
  }) {
    final storage = ModelStorage(root: root);
    final descriptor = ModelDescriptor(
      id: 'test-model',
      displayName: 'Test model',
      fileName: 'test-model.litertlm',
      licensePage: 'https://example.invalid/terms',
      downloadUri: Uri.parse('https://example.invalid/test-model.litertlm'),
      sha256Hex: pinnedHash,
    );
    final provisioner = ModelProvisioner(
      storage: storage,
      downloader: _FakeDownloader(body: body, failure: failure),
    );
    final container = ProviderContainer(
      overrides: [
        activeModelDescriptorProvider.overrideWithValue(descriptor),
        modelStorageProvider.overrideWith((ref) async => storage),
        modelProvisionerProvider.overrideWith((ref) async => provisioner),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(provisioner.dispose);
    return container;
  }

  /// SHA-256 of the four bytes `[1, 2, 3, 4]`.
  const goodHash =
      '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a';
  const wrongHash =
      '0000000000000000000000000000000000000000000000000000000000000000';

  test('a verified download reports success with the installed size', () async {
    final container = containerFor(body: [1, 2, 3, 4], pinnedHash: goodHash);
    final controller = container.read(
      modelProvisioningControllerProvider.notifier,
    );

    await controller.provision();

    final state = container.read(modelProvisioningControllerProvider);
    expect(state, isA<ProvisioningSucceeded>());
    expect((state as ProvisioningSucceeded).sizeBytes, 4);
    expect(state.source, ModelVerificationSource.download);
  });

  test('progress is reported while the transfer runs', () async {
    // The banner shows an indeterminate indicator when the fraction is null, so a
    // controller that never reported progress would look identical to a stalled one.
    final container = containerFor(body: [1, 2, 3, 4], pinnedHash: goodHash);
    final controller = container.read(
      modelProvisioningControllerProvider.notifier,
    );

    final seen = <ModelProvisioningState>[];
    container.listen(
      modelProvisioningControllerProvider,
      (_, next) => seen.add(next),
      fireImmediately: true,
    );

    await controller.provision();

    expect(seen.whereType<ProvisioningRunning>(), isNotEmpty);
    expect(seen.last, isA<ProvisioningSucceeded>());
  });

  test('a download that fails its digest is not retryable', () async {
    final container = containerFor(body: [1, 2, 3, 4], pinnedHash: wrongHash);
    final controller = container.read(
      modelProvisioningControllerProvider.notifier,
    );

    await controller.provision();

    final state =
        container.read(modelProvisioningControllerProvider)
            as ProvisioningFailed;
    expect(state.retryable, isFalse);
    // The message has to point at the configuration, because that is what is wrong:
    // the URL and the pin describe different bytes. Both digests are named, since
    // "which one is wrong" is not something the app can know — only the operator can
    // compare them against the revision they meant to pin.
    expect(state.message, contains(wrongHash));
    expect(state.message, contains(goodHash));
    expect(state.message, contains('rather than retrying'));
  });

  test('a second tap after a rejected digest does not transfer again', () async {
    // The whole point of the rule. A tap-to-retry button over a mistyped pin is a way
    // to spend a technician's data plan on a configuration error.
    final downloader = _FakeDownloader(body: [1, 2, 3, 4]);
    final storage = ModelStorage(root: root);
    final descriptor = ModelDescriptor(
      id: 'test-model',
      displayName: 'Test model',
      fileName: 'test-model.litertlm',
      licensePage: 'https://example.invalid/terms',
      downloadUri: Uri.parse('https://example.invalid/test-model.litertlm'),
      sha256Hex: wrongHash,
    );
    final provisioner = ModelProvisioner(
      storage: storage,
      downloader: downloader,
    );
    final container = ProviderContainer(
      overrides: [
        activeModelDescriptorProvider.overrideWithValue(descriptor),
        modelStorageProvider.overrideWith((ref) async => storage),
        modelProvisionerProvider.overrideWith((ref) async => provisioner),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(provisioner.dispose);

    final controller = container.read(
      modelProvisioningControllerProvider.notifier,
    );
    await controller.provision();
    expect(downloader.openCount, 1);

    await controller.provision();

    expect(
      downloader.openCount,
      1,
      reason: 'the second attempt must not reach the network',
    );
    expect(
      (container.read(modelProvisioningControllerProvider)
              as ProvisioningFailed)
          .message,
      contains('same way'),
    );
  });

  test('a corrected pin lifts the block', () async {
    // The block is about *this* pin. A new digest is a genuinely different question —
    // a corrected define, or a revision that moved — and must be allowed to fetch.
    final downloader = _FakeDownloader(body: [1, 2, 3, 4]);
    final storage = ModelStorage(root: root);
    var descriptor = ModelDescriptor(
      id: 'test-model',
      displayName: 'Test model',
      fileName: 'test-model.litertlm',
      licensePage: 'https://example.invalid/terms',
      downloadUri: Uri.parse('https://example.invalid/test-model.litertlm'),
      sha256Hex: wrongHash,
    );
    final provisioner = ModelProvisioner(
      storage: storage,
      downloader: downloader,
    );
    final container = ProviderContainer(
      overrides: [
        activeModelDescriptorProvider.overrideWith((ref) => descriptor),
        modelStorageProvider.overrideWith((ref) async => storage),
        modelProvisionerProvider.overrideWith((ref) async => provisioner),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(provisioner.dispose);

    final controller = container.read(
      modelProvisioningControllerProvider.notifier,
    );
    await controller.provision();
    expect(downloader.openCount, 1);

    // The operator fixes the define and relaunches into the same session state.
    descriptor = descriptor.withSource(
      downloadUri: descriptor.downloadUri,
      sha256Hex: goodHash,
    );
    container.invalidate(activeModelDescriptorProvider);

    await controller.provision();

    expect(downloader.openCount, 2);
    expect(
      container.read(modelProvisioningControllerProvider),
      isA<ProvisioningSucceeded>(),
    );
  });

  test('a transport failure stays retryable', () async {
    // A basement with no signal is this app's whole premise; refusing to retry that
    // would be the opposite of the intended rule.
    final container = containerFor(
      body: const [],
      pinnedHash: goodHash,
      failure: const ModelDownloadException('connection reset'),
    );
    final controller = container.read(
      modelProvisioningControllerProvider.notifier,
    );

    await controller.provision();

    final state =
        container.read(modelProvisioningControllerProvider)
            as ProvisioningFailed;
    expect(state.retryable, isTrue);
    expect(state.message, contains('connection reset'));
  });

  test('a transport failure does not block a later good download', () async {
    final downloader = _FakeDownloader(
      body: [1, 2, 3, 4],
      failure: const ModelDownloadException('connection reset'),
    );
    final storage = ModelStorage(root: root);
    final descriptor = ModelDescriptor(
      id: 'test-model',
      displayName: 'Test model',
      fileName: 'test-model.litertlm',
      licensePage: 'https://example.invalid/terms',
      downloadUri: Uri.parse('https://example.invalid/test-model.litertlm'),
      sha256Hex: goodHash,
    );
    final provisioner = ModelProvisioner(
      storage: storage,
      downloader: downloader,
    );
    final container = ProviderContainer(
      overrides: [
        activeModelDescriptorProvider.overrideWithValue(descriptor),
        modelStorageProvider.overrideWith((ref) async => storage),
        modelProvisionerProvider.overrideWith((ref) async => provisioner),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(provisioner.dispose);

    final controller = container.read(
      modelProvisioningControllerProvider.notifier,
    );
    await controller.provision();
    expect(
      container.read(modelProvisioningControllerProvider),
      isA<ProvisioningFailed>(),
    );

    downloader.failure = null;
    await controller.provision();

    expect(
      container.read(modelProvisioningControllerProvider),
      isA<ProvisioningSucceeded>(),
    );
  });

  test(
    'an unconfigured build is refused without touching the network',
    () async {
      final storage = ModelStorage(root: root);
      final downloader = _FakeDownloader(body: const [1]);
      const descriptor = ModelDescriptor(
        id: 'test-model',
        displayName: 'Test model',
        fileName: 'test-model.litertlm',
        licensePage: 'https://example.invalid/terms',
      );
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: downloader,
      );
      final container = ProviderContainer(
        overrides: [
          activeModelDescriptorProvider.overrideWithValue(descriptor),
          modelStorageProvider.overrideWith((ref) async => storage),
          modelProvisionerProvider.overrideWith((ref) async => provisioner),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(provisioner.dispose);

      await container
          .read(modelProvisioningControllerProvider.notifier)
          .provision();

      final state =
          container.read(modelProvisioningControllerProvider)
              as ProvisioningFailed;
      expect(state.message, contains('FIELDOPS_MODEL_URI'));
      // Nothing to retry until a build input changes.
      expect(state.retryable, isFalse);
      expect(downloader.openCount, 0);
    },
  );

  test('a tap during an in-flight transfer does not re-enter', () async {
    // Rewritten after review, because the first version passed for a reason that had
    // nothing to do with this task's code. It called `provision()` twice in a row and
    // asserted the downloader opened once — but the *provisioner* already guarantees
    // that: calls are serialised, and by the time the second one runs the first has
    // installed a receipt, so `statusOf == ready` short-circuits before the network.
    // Deleting the controller's guard entirely left all nine tests green.
    //
    // What the guard actually protects is re-entry *while a transfer is running*: a
    // second `provision()` would attach a second progress callback to the same state
    // field, and the two would interleave their writes. So the transfer here is held
    // open until the second tap has been made and rejected.
    final gate = Completer<void>();
    final downloader = _FakeDownloader(body: [1, 2, 3, 4], gate: gate);
    final storage = ModelStorage(root: root);
    final descriptor = ModelDescriptor(
      id: 'test-model',
      displayName: 'Test model',
      fileName: 'test-model.litertlm',
      licensePage: 'https://example.invalid/terms',
      downloadUri: Uri.parse('https://example.invalid/test-model.litertlm'),
      sha256Hex: goodHash,
    );
    final provisioner = ModelProvisioner(
      storage: storage,
      downloader: downloader,
    );
    final container = ProviderContainer(
      overrides: [
        activeModelDescriptorProvider.overrideWithValue(descriptor),
        modelStorageProvider.overrideWith((ref) async => storage),
        modelProvisionerProvider.overrideWith((ref) async => provisioner),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(provisioner.dispose);

    final controller = container.read(
      modelProvisioningControllerProvider.notifier,
    );

    var runningTransitions = 0;
    container.listen(modelProvisioningControllerProvider, (_, next) {
      if (next is ProvisioningRunning) runningTransitions++;
    });

    final first = controller.provision();
    // Let the first call reach the (gated) transfer, so the state really is
    // ProvisioningRunning when the second tap arrives.
    await pumpEventQueue();
    expect(
      container.read(modelProvisioningControllerProvider),
      isA<ProvisioningRunning>(),
    );
    final transitionsBeforeSecondTap = runningTransitions;

    // The second tap, mid-transfer. It must be dropped on the floor.
    await controller.provision();

    expect(
      runningTransitions,
      transitionsBeforeSecondTap,
      reason:
          'the refused tap must not write the state field the running transfer '
          'is reporting into',
    );
    expect(
      downloader.openCount,
      1,
      reason: 'the refused tap must not open a second transfer',
    );

    gate.complete();
    await first;

    expect(
      container.read(modelProvisioningControllerProvider),
      isA<ProvisioningSucceeded>(),
      reason: 'the refused tap must not have disturbed the running transfer',
    );
    expect(downloader.openCount, 1);
  });

  test('two sequential taps do not re-download an installed model', () async {
    // The property the old overlap test was accidentally asserting. Worth keeping
    // *as itself*: it is the provisioner's serialisation plus its ready
    // short-circuit, and it is what makes the button safe to tap twice slowly.
    final downloader = _FakeDownloader(body: [1, 2, 3, 4]);
    final storage = ModelStorage(root: root);
    final descriptor = ModelDescriptor(
      id: 'test-model',
      displayName: 'Test model',
      fileName: 'test-model.litertlm',
      licensePage: 'https://example.invalid/terms',
      downloadUri: Uri.parse('https://example.invalid/test-model.litertlm'),
      sha256Hex: goodHash,
    );
    final provisioner = ModelProvisioner(
      storage: storage,
      downloader: downloader,
    );
    final container = ProviderContainer(
      overrides: [
        activeModelDescriptorProvider.overrideWithValue(descriptor),
        modelStorageProvider.overrideWith((ref) async => storage),
        modelProvisionerProvider.overrideWith((ref) async => provisioner),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(provisioner.dispose);

    final controller = container.read(
      modelProvisioningControllerProvider.notifier,
    );
    await controller.provision();
    await controller.provision();

    expect(downloader.openCount, 1);
    expect(
      container.read(modelProvisioningControllerProvider),
      isA<ProvisioningSucceeded>(),
    );
  });
}

/// A [ModelDownloader] that serves a fixed body, or fails.
class _FakeDownloader implements ModelDownloader {
  _FakeDownloader({required this.body, this.failure, this.gate});

  final List<int> body;
  ModelDownloadException? failure;

  /// When set, the body is withheld until it completes — which is what lets a test
  /// hold a transfer genuinely in flight while it does something else.
  final Completer<void>? gate;

  int openCount = 0;

  @override
  Future<ModelByteStream> open(Uri uri, {String? authToken}) async {
    openCount++;
    final error = failure;
    if (error != null) throw error;
    final held = gate;
    return ModelByteStream(
      bytes: held == null
          ? Stream.value(body)
          // The stream stays open (and the provisioner stays inside its transfer
          // loop) until the gate opens.
          : Stream.fromFuture(held.future.then((_) => body)),
      contentLength: body.length,
    );
  }

  @override
  void close() {}
}
