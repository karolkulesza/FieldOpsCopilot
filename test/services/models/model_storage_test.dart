import 'dart:io';

import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for model storage layout and the no-backup marking.
///
/// The platform mechanism is injected rather than sniffed from `Platform`, so
/// these assertions run identically on the macOS dev host and the Linux CI
/// runner. A test that silently takes a different branch per runner is not a
/// test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  const descriptor = ModelDescriptor(
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

  group('layout', () {
    test('artifact, staging and receipt paths are distinct and namespaced', () {
      final storage = storageWith(const NoopBackupExclusion());

      expect(
        storage.installedFile(descriptor).path,
        '${storage.root.path}/gemma-test.litertlm',
      );
      expect(
        storage.stagingFile(descriptor).path,
        '${storage.root.path}/gemma-test.litertlm.part',
      );
      // The staging suffix must not collide with the installed name, or the
      // atomic rename would be a no-op onto itself.
      expect(
        storage.stagingFile(descriptor).path,
        isNot(storage.installedFile(descriptor).path),
      );
      expect(
        storage.receiptFile(descriptor).path,
        '${storage.root.path}/gemma-test.litertlm.receipt.json',
      );
    });

    test(
      'deleteArtifact removes the artifact, staging file and receipt',
      () async {
        final storage = storageWith(const NoopBackupExclusion());
        await storage.prepare();
        await storage.installedFile(descriptor).writeAsString('weights');
        await storage.stagingFile(descriptor).writeAsString('partial');
        await storage.writeReceipt(descriptor, sha256Hex: 'x', sizeBytes: 7);

        await storage.deleteArtifact(descriptor);

        expect(storage.installedFile(descriptor).existsSync(), isFalse);
        expect(storage.stagingFile(descriptor).existsSync(), isFalse);
        expect(storage.receiptFile(descriptor).existsSync(), isFalse);
      },
    );
  });

  group('receipts', () {
    test('a written receipt round-trips', () async {
      final storage = storageWith(const NoopBackupExclusion());
      await storage.prepare();
      await storage.writeReceipt(descriptor, sha256Hex: 'abc', sizeBytes: 42);

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
