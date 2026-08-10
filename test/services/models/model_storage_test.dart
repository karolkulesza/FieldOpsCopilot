import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for model storage layout, the Task 2.0 file-set status
/// rules, the legacy-layout migration and the no-backup marking.
///
/// The platform mechanism is injected rather than sniffed from `Platform`, so
/// these assertions run identically on the macOS dev host and the Linux CI
/// runner. A test that silently takes a different branch per runner is not a
/// test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  final descriptor = ModelDescriptor(
    id: 'gemma-test',
    displayName: 'Gemma (test fixture)',
    fileName: 'gemma-test.litertlm',
    licensePage: 'https://example.invalid/license',
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_storage_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  ModelStorage storageWith(BackupExclusion exclusion) => ModelStorage(
    root: Directory('${tempDir.path}/models'),
    backupExclusion: exclusion,
  );

  /// A four-file descriptor shaped like the STT set, with pins over tiny
  /// deterministic bodies so a "verified" state can be built by hand.
  ModelDescriptor setDescriptor() => ModelDescriptor.fileSet(
    id: 'stt-test',
    displayName: 'STT (test fixture)',
    licensePage: 'https://example.invalid/license',
    files: [
      for (final name in [
        'encoder.onnx',
        'decoder.onnx',
        'joiner.onnx',
        'tokens.txt',
      ])
        ModelArtifactFile(
          fileName: name,
          downloadUri: Uri.parse('https://example.invalid/$name'),
          sha256Hex: sha256.convert(utf8.encode('body of $name')).toString(),
          approximateSizeBytes: utf8.encode('body of $name').length,
        ),
    ],
  );

  /// Writes every file of [d] with the exact bytes its pin describes, plus a
  /// matching receipt — the on-disk state a successful install leaves behind.
  Future<void> installVerified(ModelStorage storage, ModelDescriptor d) async {
    await storage.installDir(d).create(recursive: true);
    for (final file in d.files) {
      final bytes = utf8.encode('body of ${file.fileName}');
      await storage.installedFile(d, file).writeAsBytes(bytes);
      await storage.writeReceipt(
        d,
        file: file,
        sha256Hex: file.sha256Hex,
        sizeBytes: bytes.length,
      );
    }
  }

  group('layout', () {
    test('artifact, staging and receipt paths are distinct and namespaced', () {
      final storage = storageWith(const NoopBackupExclusion());

      // Task 2.0: each model owns a subdirectory named by its id, so two
      // models' files cannot collide however they are named.
      expect(
        storage.installedFile(descriptor).path,
        '${storage.root.path}/gemma-test/gemma-test.litertlm',
      );
      expect(
        storage.stagingDir(descriptor).path,
        '${storage.root.path}/gemma-test.part',
      );
      // The staging suffix must not collide with the install directory, or the
      // rename into place would be a no-op onto itself.
      expect(
        storage.stagingDir(descriptor).path,
        isNot(storage.installDir(descriptor).path),
      );
      expect(
        storage.receiptFile(descriptor).path,
        '${storage.root.path}/gemma-test/gemma-test.litertlm.receipt.json',
      );
    });

    test('two models with one file name do not collide', () {
      final storage = storageWith(const NoopBackupExclusion());
      final other = ModelDescriptor(
        id: 'other-model',
        displayName: 'Other',
        fileName: 'gemma-test.litertlm',
        licensePage: 'https://example.invalid/license',
      );

      expect(
        storage.installedFile(descriptor).path,
        isNot(storage.installedFile(other).path),
      );
    });

    test(
      'deleteArtifact removes the install directory, staging and receipts',
      () async {
        final storage = storageWith(const NoopBackupExclusion());
        await storage.prepare();
        await storage.installDir(descriptor).create(recursive: true);
        await storage.installedFile(descriptor).writeAsString('weights');
        await storage.stagingDir(descriptor).create(recursive: true);
        await storage.writeReceipt(
          descriptor,
          file: descriptor.soleFile,
          sha256Hex: 'x',
          sizeBytes: 7,
        );

        await storage.deleteArtifact(descriptor);

        expect(storage.installedFile(descriptor).existsSync(), isFalse);
        expect(storage.stagingDir(descriptor).existsSync(), isFalse);
        expect(storage.receiptFile(descriptor).existsSync(), isFalse);
        expect(storage.installDir(descriptor).existsSync(), isFalse);
      },
    );
  });

  group('file-set status (TC-PROV-SET-01)', () {
    test('ready only while every file verifies — removal of each file in turn '
        'flips the status', () async {
      final storage = storageWith(const NoopBackupExclusion());
      await storage.prepare();
      final d = setDescriptor();
      await installVerified(storage, d);

      expect(await storage.statusOf(d), ModelInstallStatus.ready);

      // Not just the first file: the AC exists precisely because a status
      // check that stops at files.first would report ready over a hole.
      for (final file in d.files) {
        final installed = storage.installedFile(d, file);
        final bytes = await installed.readAsBytes();
        await installed.delete();

        expect(
          await storage.statusOf(d),
          ModelInstallStatus.absent,
          reason: '${file.fileName} is missing, so the set is not ready',
        );

        await installed.writeAsBytes(bytes);
        expect(await storage.statusOf(d), ModelInstallStatus.ready);
      }
    });

    test(
      'a stale receipt on any single file demotes the set to unverified',
      () async {
        final storage = storageWith(const NoopBackupExclusion());
        await storage.prepare();
        final d = setDescriptor();
        await installVerified(storage, d);

        for (final file in d.files) {
          final receipt = storage.receiptFile(d, file);
          final original = await receipt.readAsString();
          // A receipt for a different pin: the bytes moved since it was written.
          await receipt.writeAsString(
            original.replaceFirst(file.sha256Hex, 'f' * 64),
          );

          expect(
            await storage.statusOf(d),
            ModelInstallStatus.unverified,
            reason: '${file.fileName}\'s receipt no longer vouches',
          );

          await receipt.writeAsString(original);
          expect(await storage.statusOf(d), ModelInstallStatus.ready);
        }
      },
    );
  });

  group('legacy layout migration', () {
    test('a Task 1.7 flat install is moved into the model directory and stays '
        'ready without re-hashing', () async {
      final storage = storageWith(const NoopBackupExclusion());
      await storage.prepare();
      final file = descriptor.soleFile;
      final bytes = utf8.encode('legacy gemma weights');
      final digest = sha256.convert(bytes).toString();
      final pinned = ModelCatalog.resolve(
        descriptor,
        uri: 'https://example.invalid/w.litertlm',
        sha256Hex: digest,
      );
      // The flat layout 1.7 wrote: file and receipt sidecar directly in root.
      await File('${storage.root.path}/${file.fileName}').writeAsBytes(bytes);
      await File(
        '${storage.root.path}/${file.fileName}.receipt.json',
      ).writeAsString(
        jsonEncode({
          'modelId': pinned.id,
          'sha256': digest,
          'sizeBytes': bytes.length,
        }),
      );

      expect(await storage.statusOf(pinned), ModelInstallStatus.ready);

      // Physically moved, not copied or re-fetched.
      expect(
        File('${storage.root.path}/${file.fileName}').existsSync(),
        isFalse,
      );
      expect(storage.installedFile(pinned).existsSync(), isTrue);
      expect(await storage.installedFile(pinned).readAsBytes(), bytes);
      expect(storage.receiptFile(pinned).existsSync(), isTrue);
    });

    test(
      'a flat file never overwrites an install already in the new layout',
      () async {
        final storage = storageWith(const NoopBackupExclusion());
        await storage.prepare();
        final file = descriptor.soleFile;
        await storage.installDir(descriptor).create(recursive: true);
        await storage.installedFile(descriptor).writeAsString('current');
        await File(
          '${storage.root.path}/${file.fileName}',
        ).writeAsString('stale flat leftover');

        await storage.statusOf(descriptor);

        expect(
          await storage.installedFile(descriptor).readAsString(),
          'current',
        );
      },
    );
  });

  group('receipts', () {
    test('a written receipt round-trips', () async {
      final storage = storageWith(const NoopBackupExclusion());
      await storage.prepare();
      await storage.installDir(descriptor).create(recursive: true);
      await storage.writeReceipt(
        descriptor,
        file: descriptor.soleFile,
        sha256Hex: 'abc',
        sizeBytes: 42,
      );

      final receipt = await storage.readReceipt(descriptor);

      expect(receipt, isNotNull);
      expect(receipt!.modelId, descriptor.id);
      expect(receipt.sha256Hex, 'abc');
      expect(receipt.sizeBytes, 42);
    });

    test('malformed receipts parse to null instead of throwing', () {
      expect(ModelInstallReceipt.tryParse('{not json'), isNull);
      expect(ModelInstallReceipt.tryParse('[]'), isNull);
      expect(ModelInstallReceipt.tryParse('"a string"'), isNull);
      // Wrong types for the fields that matter.
      expect(
        ModelInstallReceipt.tryParse(
          '{"modelId":"m","sha256":"h","sizeBytes":"42"}',
        ),
        isNull,
      );
      expect(ModelInstallReceipt.tryParse('{"modelId":"m"}'), isNull);
    });
  });

  group('backup exclusion', () {
    test('the manifest mechanism needs no channel call', () async {
      final calls = _recordChannelCalls();
      final exclusion = const PlatformBackupExclusion(
        mechanism: BackupExclusionMechanism.manifest,
      );

      expect(await exclusion.exclude(tempDir), isTrue);
      expect(
        calls,
        isEmpty,
        reason: 'Android excludes declaratively, before the app runs',
      );
    });

    test('the resource-attribute mechanism calls the native handler', () async {
      final calls = _recordChannelCalls(result: true);
      final exclusion = const PlatformBackupExclusion(
        mechanism: BackupExclusionMechanism.resourceAttribute,
      );

      expect(await exclusion.exclude(tempDir), isTrue);
      expect(calls, hasLength(1));
      // This is the contract with AppDelegate.swift: rename either side and this
      // fails rather than silently going quiet.
      expect(calls.single.method, 'excludeFromBackup');
      expect(calls.single.arguments, {'path': tempDir.path});
    });

    test(
      'an unimplemented channel reports false rather than throwing',
      () async {
        // No handler registered at all — a host build, or an iOS target whose
        // AppDelegate lost the registration.
        const exclusion = PlatformBackupExclusion(
          mechanism: BackupExclusionMechanism.resourceAttribute,
        );

        expect(await exclusion.exclude(tempDir), isFalse);
      },
    );

    test('a native failure reports false rather than throwing', () async {
      _recordChannelCalls(
        error: PlatformException(code: 'exclude_failed', message: 'nope'),
      );
      const exclusion = PlatformBackupExclusion(
        mechanism: BackupExclusionMechanism.resourceAttribute,
      );

      expect(
        await exclusion.exclude(tempDir),
        isFalse,
        reason:
            'a downloaded model stays usable even if the flag did not stick',
      );
    });

    test('a native null answer is not read as success', () async {
      _recordChannelCalls();
      const exclusion = PlatformBackupExclusion(
        mechanism: BackupExclusionMechanism.resourceAttribute,
      );

      expect(await exclusion.exclude(tempDir), isFalse);
    });

    test('an unsupported platform reports false', () async {
      final calls = _recordChannelCalls(result: true);
      const exclusion = PlatformBackupExclusion(
        mechanism: BackupExclusionMechanism.none,
      );

      expect(await exclusion.exclude(tempDir), isFalse);
      expect(calls, isEmpty);
    });

    test('prepare passes the created directory to the exclusion', () async {
      final spy = _SpyBackupExclusion(answer: true);
      final storage = storageWith(spy);

      expect(await storage.prepare(), isTrue);
      expect(spy.excluded.single.path, storage.root.path);
      expect(storage.root.existsSync(), isTrue);
    });

    test('the host platform maps to a defined mechanism', () {
      // Not a tautology: it pins the mapping for the platforms in play — the two
      // this app ships on and the hosts the tests run on — so adding a target
      // forces a decision here rather than silently landing on `none`.
      final mechanism = PlatformBackupExclusion.mechanismFor();
      if (Platform.isAndroid) {
        expect(mechanism, BackupExclusionMechanism.manifest);
      } else if (Platform.isIOS || Platform.isMacOS) {
        expect(mechanism, BackupExclusionMechanism.resourceAttribute);
      } else {
        expect(mechanism, BackupExclusionMechanism.none);
      }
    });
  });
}

/// Installs a mock handler on the model-storage channel and returns the calls it
/// receives.
List<MethodCall> _recordChannelCalls({
  Object? result,
  PlatformException? error,
}) {
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(PlatformBackupExclusion.channel, (
    call,
  ) async {
    calls.add(call);
    if (error != null) throw error;
    return result;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(
      PlatformBackupExclusion.channel,
      null,
    ),
  );
  return calls;
}

/// A [BackupExclusion] that records what it was asked to exclude.
class _SpyBackupExclusion implements BackupExclusion {
  _SpyBackupExclusion({required this.answer});

  final bool answer;
  final List<Directory> excluded = [];

  @override
  Future<bool> exclude(Directory directory) async {
    excluded.add(directory);
    return answer;
  }
}
