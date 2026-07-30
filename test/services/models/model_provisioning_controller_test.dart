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

  test('overlapping taps do not start a second transfer', () async {
    // The provisioner serialises internally, so a second call is not *unsafe* — it is
    // just a second progress stream fighting the first for the same state field.
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
    final first = controller.provision();
    final second = controller.provision();
    await Future.wait([first, second]);

    expect(downloader.openCount, 1);
  });
}

/// A [ModelDownloader] that serves a fixed body, or fails.
class _FakeDownloader implements ModelDownloader {
  _FakeDownloader({required this.body, this.failure});

  final List<int> body;
  ModelDownloadException? failure;

  int openCount = 0;

  @override
  Future<ModelByteStream> open(Uri uri, {String? authToken}) async {
    openCount++;
    final error = failure;
    if (error != null) throw error;
    return ModelByteStream(
      bytes: Stream.value(body),
      contentLength: body.length,
    );
  }

  @override
  void close() {}
}
