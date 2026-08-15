import 'dart:io';

import 'package:field_ops_copilot/services/audio/providers.dart';
import 'package:field_ops_copilot/services/audio/stt_config.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:field_ops_copilot/services/models/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The voice half of Task 2.3's wiring, at the seam where "there is no model" has
/// to be an ordinary answer rather than a crash.
///
/// The engine providers themselves cannot be resolved on a host — building a
/// `SherpaSttEngine` spawns an isolate that `dlopen`s a framework — so what is
/// asserted here is the decision *above* it: which install states produce a config
/// at all, and that the four paths point where Task 2.0 installs the files.
void main() {
  // `RecordAudioInput` builds an `AudioRecorder`, which touches `ServicesBinding`.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fieldops_audio_providers');
  });
  tearDown(() => root.deleteSync(recursive: true));

  final descriptor = ModelCatalog.byId(ModelCatalog.sttZipformerId)!;

  /// A container whose STT model reports [status].
  ProviderContainer containerFor(ModelInstallStatus status) {
    final container = ProviderContainer(
      overrides: [
        modelStorageProvider.overrideWith(
          (ref) async => ModelStorage(root: root),
        ),
        modelInstallStatusProvider(
          descriptor.id,
        ).overrideWith((ref) async => status),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('sttConfigProvider', () {
    test('a ready set yields a config over the install directory', () async {
      final container = containerFor(ModelInstallStatus.ready);

      final config = await container.read(sttConfigProvider.future);

      expect(config, isNotNull);
      final directory = ModelStorage(root: root).installDir(descriptor).path;
      expect(
        config!.files.encoder,
        '$directory/${SttModelFiles.encoderFileName}',
      );
      expect(
        config.files.decoder,
        '$directory/${SttModelFiles.decoderFileName}',
      );
      expect(config.files.joiner, '$directory/${SttModelFiles.joinerFileName}');
      expect(config.files.tokens, '$directory/${SttModelFiles.tokensFileName}');
    });

    // The rule `inferenceConfigProvider` set and this one repeats: `ready` and
    // nothing weaker. `unverified` means the four files are at the right paths and
    // nothing has hashed them — and a recogniser built from a truncated encoder
    // does not fail, it transcribes noise.
    test('every state short of ready yields no config', () async {
      for (final status in ModelInstallStatus.values) {
        if (status == ModelInstallStatus.ready) continue;
        expect(
          await containerFor(status).read(sttConfigProvider.future),
          isNull,
          reason: status.name,
        );
      }
    });

    test('a build that provisions no STT model yields no config', () async {
      final container = ProviderContainer(
        overrides: [
          provisionedModelDescriptorsProvider.overrideWithValue([
            ModelCatalog.active,
          ]),
          modelStorageProvider.overrideWith(
            (ref) async => ModelStorage(root: root),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(await container.read(sttConfigProvider.future), isNull);
      expect(container.read(sttDescriptorProvider), isNull);
    });

    // The paths this composes are only right because the file *names* on
    // `SttModelFiles` are the ones the catalog installs under. `stt_config_test`
    // asserts those agree; this asserts the composition uses them, which is the
    // other half — a config built from a directory and the wrong four names would
    // pass that test and fail on the device with "no such file".
    test('the composed paths are the ones the provisioner installs', () async {
      final container = containerFor(ModelInstallStatus.ready);
      final storage = ModelStorage(root: root);

      final config = (await container.read(sttConfigProvider.future))!;

      final installed = {
        for (final file in descriptor.files)
          storage.installedFile(descriptor, file).path,
      };
      expect({
        config.files.encoder,
        config.files.decoder,
        config.files.joiner,
        config.files.tokens,
      }, installed);
    });
  });

  group('the STT descriptor', () {
    test('it is the catalog entry Task 2.0 committed', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(sttDescriptorProvider), same(descriptor));
      expect(descriptor.files, hasLength(4));
    });

    // Resolved through `modelDescriptorProvider` rather than `ModelCatalog.byId`,
    // so an overridden provisioned list overrides this too. Stated in the doc; a
    // direct catalog lookup would pass every other test in this file.
    test('it follows an overridden provisioned list', () {
      final container = ProviderContainer(
        overrides: [
          provisionedModelDescriptorsProvider.overrideWithValue(const []),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(sttDescriptorProvider), isNull);
    });
  });

  group('micCaptureProvider', () {
    test('it hands out one microphone, at the STT capture format', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final first = container.read(micCaptureProvider);
      final second = container.read(micCaptureProvider);

      expect(
        identical(first, second),
        isTrue,
        reason:
            'a second MicCapture makes the busy refusal and the release wait '
            'vacuous — record silently closes the first stream',
      );
      // The format the recogniser is built at, read off a config rather than
      // restated: a microphone at 44.1kHz feeding a 16kHz zipformer transcribes
      // nonsense rather than failing.
      expect(
        first.format,
        SttConfig.forInstallDirectory('/does-not-matter').format,
      );
      expect(first.stallTimeout, isNotNull);
    });
  });
}
