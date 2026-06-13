import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_downloader.dart';
import 'package:field_ops_copilot/services/models/model_provisioner.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for Task 1.7 (model provisioning & delivery).
///
/// Everything here runs on the host with no network: the download seam is a
/// scripted byte stream, and the "model" is a few hundred bytes of fixture whose
/// SHA-256 is computed in the test rather than hard-coded — a literal digest
/// would only prove that two constants match.
void main() {
  late Directory tempDir;
  late ModelStorage storage;

  /// A stand-in artifact. Small, but exercised through the same streaming
  /// hash-while-writing path a 2.4GB file uses.
  final fixtureBytes = Uint8List.fromList(
    utf8.encode('gemma-4-e2b weights stand-in ' * 40),
  );
  final fixtureDigest = sha256.convert(fixtureBytes).toString();

  /// A valid-shaped digest that is not [fixtureDigest].
  const wrongDigest =
      '0000000000000000000000000000000000000000000000000000000000000000';

  ModelDescriptor descriptorWith({
    String? sha256Hex,
    String? uri = _sourceUrl,
    int? approximateSizeBytes,
  }) => ModelDescriptor(
    id: 'gemma-test',
    displayName: 'Gemma (test fixture)',
    fileName: 'gemma-test.litertlm',
    licensePage: 'https://example.invalid/license',
    downloadUri: uri == null ? null : Uri.parse(uri),
    sha256Hex: sha256Hex ?? fixtureDigest,
    approximateSizeBytes: approximateSizeBytes,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_model_test');
    storage = ModelStorage(root: Directory('${tempDir.path}/models'));
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('hash verification', () {
    // TC-PROV-HASH-01: a download whose bytes match the pinned SHA-256 verifies.
    test('matching digest installs the artifact and reports verified', () async {
      final descriptor = descriptorWith();
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(body: fixtureBytes),
      );

      final result = await provisioner.provision(descriptor);

      expect(result, isA<ModelVerified>());
      final verified = result as ModelVerified;
      expect(verified.sha256Hex, fixtureDigest);
      expect(verified.sizeBytes, fixtureBytes.length);
      expect(verified.source, ModelVerificationSource.download);

      // The artifact is where the engine will look for it, with the right bytes.
      final installed = storage.installedFile(descriptor);
      expect(installed.existsSync(), isTrue);
      expect(await installed.readAsBytes(), fixtureBytes);
      // Staging is cleaned up by the rename, so no half-file is left behind.
      expect(storage.stagingFile(descriptor).existsSync(), isFalse);
    });

    // TC-PROV-HASH-02: a download whose bytes do not match the pinned SHA-256 is
    // reported corrupt and the bytes are removed.
    test(
      'mismatched digest reports corrupt and quarantines the bytes',
      () async {
        final descriptor = descriptorWith(sha256Hex: wrongDigest);
        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(body: fixtureBytes),
        );

        final result = await provisioner.provision(descriptor);

        expect(result, isA<ModelCorrupt>());
        final corrupt = result as ModelCorrupt;
        expect(corrupt.expectedSha256Hex, wrongDigest);
        // The actual digest is reported so a mismatch is diagnosable without
        // keeping the rejected bytes around.
        expect(corrupt.actualSha256Hex, fixtureDigest);
        expect(corrupt.quarantined, isTrue);

        // Nothing installable survives: not the artifact, not the staging file,
        // and no receipt that a later download could inherit.
        expect(storage.installedFile(descriptor).existsSync(), isFalse);
        expect(storage.stagingFile(descriptor).existsSync(), isFalse);
        expect(storage.receiptFile(descriptor).existsSync(), isFalse);
        expect(await storage.statusOf(descriptor), ModelInstallStatus.absent);
      },
    );

    test(
      'a source serving different bytes cannot replace a verified install',
      () async {
        final descriptor = descriptorWith();
        final first = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(body: fixtureBytes),
        );
        expect(await first.provision(descriptor), isA<ModelVerified>());

        // The source now serves something else — a rolled revision, a corrupted
        // mirror, a captive-portal HTML page. The pin has not moved, so the
        // installed artifact is still the right one and must not be touched.
        final mirror = _ScriptedDownloader(
          body: Uint8List.fromList(utf8.encode('<html>captive portal</html>')),
        );
        final second = ModelProvisioner(storage: storage, downloader: mirror);

        final result = await second.provision(descriptor);

        expect(result, isA<ModelVerified>());
        expect(
          (result as ModelVerified).source,
          ModelVerificationSource.receipt,
        );
        expect(mirror.openCount, 0, reason: 'nothing should have been fetched');
        expect(
          await storage.installedFile(descriptor).readAsBytes(),
          fixtureBytes,
        );
      },
    );
  });

  group('side-loaded weights', () {
    test(
      'an existing file with no receipt is hashed in place, not re-downloaded',
      () async {
        final descriptor = descriptorWith();
        await storage.prepare();
        await storage.installedFile(descriptor).writeAsBytes(fixtureBytes);

        final downloader = _ScriptedDownloader(body: fixtureBytes);
        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: downloader,
        );

        final result = await provisioner.provision(descriptor);

        expect(result, isA<ModelVerified>());
        expect(
          (result as ModelVerified).source,
          ModelVerificationSource.existingFile,
        );
        // The point of the flow: no 2.4GB transfer over venue Wi-Fi.
        expect(downloader.openCount, 0);
        // And it is now cheap to answer on the next launch.
        expect(await storage.statusOf(descriptor), ModelInstallStatus.ready);
      },
    );

    test('a side-loaded file that does not match the pin is deleted', () async {
      final descriptor = descriptorWith();
      await storage.prepare();
      await storage
          .installedFile(descriptor)
          .writeAsBytes(utf8.encode('truncated copy'));

      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(body: fixtureBytes),
      );

      final result = await provisioner.verifyInstalled(descriptor);

      expect(result, isA<ModelCorrupt>());
      expect((result as ModelCorrupt).quarantined, isTrue);
      expect(storage.installedFile(descriptor).existsSync(), isFalse);
    });

    test('verifyInstalled reports absent when nothing is installed', () async {
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(body: fixtureBytes),
      );
      expect(
        await provisioner.verifyInstalled(descriptorWith()),
        isA<ModelAbsent>(),
      );
    });

    test(
      'verifyInstalled re-hashes despite a receipt that says ready',
      () async {
        final descriptor = descriptorWith();
        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(body: fixtureBytes),
        );
        expect(await provisioner.provision(descriptor), isA<ModelVerified>());
        expect(await storage.statusOf(descriptor), ModelInstallStatus.ready);

        // Bytes rot underneath the receipt, keeping the same length so the size
        // check cannot notice. Only re-hashing can.
        final installed = storage.installedFile(descriptor);
        final rotted = Uint8List.fromList(fixtureBytes)
          ..[0] = fixtureBytes[0] ^ 0xFF;
        await installed.writeAsBytes(rotted);

        // The cheap path still trusts the receipt — that is what makes it cheap.
        expect(await storage.statusOf(descriptor), ModelInstallStatus.ready);
        // The explicit check does not.
        expect(
          await provisioner.verifyInstalled(descriptor),
          isA<ModelCorrupt>(),
        );
        expect(installed.existsSync(), isFalse);
      },
    );
  });

  group('configuration', () {
    test('refuses to provision without a source URL', () async {
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(body: fixtureBytes),
      );

      final result = await provisioner.provision(descriptorWith(uri: null));

      expect(result, isA<ModelNotConfigured>());
      expect(
        (result as ModelNotConfigured).issue,
        ModelConfigurationIssue.missingSource,
      );
    });

    test('refuses to install anything when no hash is pinned', () async {
      final descriptor = descriptorWith(sha256Hex: '');
      final downloader = _ScriptedDownloader(body: fixtureBytes);
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: downloader,
      );

      final result = await provisioner.provision(descriptor);

      expect(result, isA<ModelNotConfigured>());
      expect(
        (result as ModelNotConfigured).issue,
        ModelConfigurationIssue.unpinnedHash,
      );
      // Fail closed: unverifiable weights are never even fetched.
      expect(downloader.openCount, 0);
      expect(storage.installedFile(descriptor).existsSync(), isFalse);
    });

    test('a truncated-looking hash is not accepted as a pin', () {
      expect(descriptorWith(sha256Hex: 'abc123').hasPinnedHash, isFalse);
      expect(
        descriptorWith(sha256Hex: fixtureDigest.toUpperCase()).hasPinnedHash,
        isFalse,
        reason: 'callers normalize with ModelDescriptor.normalizeHash first',
      );
      expect(descriptorWith().hasPinnedHash, isTrue);
    });

    test('normalizeHash accepts what the shasum tools actually print', () {
      expect(
        ModelDescriptor.normalizeHash('  ${fixtureDigest.toUpperCase()}  '),
        fixtureDigest,
      );
      expect(
        ModelDescriptor.normalizeHash('$fixtureDigest  gemma.litertlm'),
        fixtureDigest,
      );
    });

    test('catalog resolution overlays the build-time source and hash', () {
      final base = ModelCatalog.byId(ModelCatalog.gemma4E2bId)!;
      // Shipped catalog entries carry no URL and no hash: both are deployment
      // inputs, so the artifact is unprovisionable until they are supplied.
      expect(base.downloadUri, isNull);
      expect(base.hasPinnedHash, isFalse);
      expect(base.configurationIssue, ModelConfigurationIssue.missingSource);

      final resolved = ModelCatalog.resolve(
        base,
        uri: 'https://example.invalid/gemma.litertlm',
        sha256Hex: fixtureDigest.toUpperCase(),
      );
      expect(
        resolved.downloadUri,
        Uri.parse('https://example.invalid/gemma.litertlm'),
      );
      expect(resolved.sha256Hex, fixtureDigest);
      expect(resolved.configurationIssue, isNull);
      // Identity and layout survive the overlay.
      expect(resolved.id, base.id);
      expect(resolved.fileName, base.fileName);
    });
  });

  group('credentials', () {
    test('the configured access token reaches the downloader', () async {
      final downloader = _ScriptedDownloader(body: fixtureBytes);
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: downloader,
        authToken: 'hf_test_token',
      );

      await provisioner.provision(descriptorWith());

      expect(downloader.lastToken, 'hf_test_token');
      expect(downloader.lastUri, Uri.parse(_sourceUrl));
    });

    test('no token configured means no credential is sent', () async {
      final downloader = _ScriptedDownloader(body: fixtureBytes);
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: downloader,
      );

      await provisioner.provision(descriptorWith());

      expect(downloader.lastToken, isNull);
    });
  });

  group('transfer failures', () {
    test(
      'an HTTP failure is reported with its status and installs nothing',
      () async {
        final descriptor = descriptorWith();
        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(
            body: fixtureBytes,
            failure: const ModelDownloadException(
              'access forbidden',
              statusCode: 403,
            ),
          ),
        );

        final result = await provisioner.provision(descriptor);

        expect(result, isA<ModelDownloadFailed>());
        expect((result as ModelDownloadFailed).statusCode, 403);
        expect(storage.installedFile(descriptor).existsSync(), isFalse);
      },
    );

    test('a stream that dies mid-body deletes the partial file', () async {
      final descriptor = descriptorWith();
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(body: fixtureBytes, failAfterBytes: 64),
      );

      final result = await provisioner.provision(descriptor);

      expect(result, isA<ModelDownloadFailed>());
      expect(storage.stagingFile(descriptor).existsSync(), isFalse);
      expect(storage.installedFile(descriptor).existsSync(), isFalse);
    });

    test(
      'a body shorter than Content-Length is a truncation, not corruption',
      () async {
        final descriptor = descriptorWith();
        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(
            body: fixtureBytes,
            // Server promises more than it sends.
            contentLengthOverride: fixtureBytes.length + 1024,
          ),
        );

        final result = await provisioner.provision(descriptor);

        expect(result, isA<ModelDownloadFailed>());
        expect(
          (result as ModelDownloadFailed).message,
          contains('truncated transfer'),
        );
        expect(storage.stagingFile(descriptor).existsSync(), isFalse);
      },
    );

    test(
      'a stale .part from an interrupted run is discarded, not appended to',
      () async {
        final descriptor = descriptorWith();
        await storage.prepare();
        await storage
            .stagingFile(descriptor)
            .writeAsBytes(utf8.encode('leftover partial body'));

        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(body: fixtureBytes),
        );

        // Appending to the leftover would produce bytes that hash to nothing and
        // surface as a phantom corruption.
        expect(await provisioner.provision(descriptor), isA<ModelVerified>());
        expect(
          await storage.installedFile(descriptor).readAsBytes(),
          fixtureBytes,
        );
      },
    );
  });

  group('progress reporting', () {
    test('download progress is monotonic and ends at the body size', () async {
      final descriptor = descriptorWith();
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(body: fixtureBytes, chunkSize: 100),
      );

      final samples = <ModelProvisionProgress>[];
      await provisioner.provision(descriptor, onProgress: samples.add);

      expect(samples, isNotEmpty);
      expect(
        samples.every((s) => s.phase == ModelProvisionPhase.downloading),
        isTrue,
      );
      // More than one sample, or "progress" would be a single jump to 100%.
      expect(samples.length, greaterThan(1));
      for (var i = 1; i < samples.length; i++) {
        expect(
          samples[i].processedBytes,
          greaterThan(samples[i - 1].processedBytes),
        );
      }
      expect(samples.last.processedBytes, fixtureBytes.length);
      expect(samples.last.fraction, 1.0);
    });

    test('progress fraction is null when no total is known', () async {
      final descriptor = descriptorWith();
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(
          body: fixtureBytes,
          // Chunked transfer encoding: no Content-Length, and the descriptor
          // documents no size either.
          contentLengthOverride: -1,
        ),
      );

      final samples = <ModelProvisionProgress>[];
      await provisioner.provision(descriptor, onProgress: samples.add);

      expect(samples, isNotEmpty);
      expect(samples.every((s) => s.totalBytes == null), isTrue);
      expect(samples.last.fraction, isNull);
    });

    test(
      'the documented size stands in for a missing Content-Length',
      () async {
        final descriptor = descriptorWith(
          approximateSizeBytes: fixtureBytes.length,
        );
        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(
            body: fixtureBytes,
            contentLengthOverride: -1,
          ),
        );

        final samples = <ModelProvisionProgress>[];
        await provisioner.provision(descriptor, onProgress: samples.add);

        expect(samples.last.totalBytes, fixtureBytes.length);
        expect(samples.last.fraction, 1.0);
      },
    );

    test(
      'verification progress is reported while hashing an existing file',
      () async {
        final descriptor = descriptorWith();
        await storage.prepare();
        await storage.installedFile(descriptor).writeAsBytes(fixtureBytes);

        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(body: fixtureBytes),
        );

        final samples = <ModelProvisionProgress>[];
        await provisioner.verifyInstalled(descriptor, onProgress: samples.add);

        expect(samples, isNotEmpty);
        expect(
          samples.every((s) => s.phase == ModelProvisionPhase.verifying),
          isTrue,
        );
        expect(samples.last.processedBytes, fixtureBytes.length);
      },
    );
  });

  group('install state', () {
    test(
      'a receipt makes the ready check free of both hashing and network',
      () async {
        final descriptor = descriptorWith();
        final downloader = _ScriptedDownloader(body: fixtureBytes);
        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: downloader,
        );

        expect(
          await provisioner.statusOf(descriptor),
          ModelInstallStatus.absent,
        );
        await provisioner.provision(descriptor);
        expect(
          await provisioner.statusOf(descriptor),
          ModelInstallStatus.ready,
        );

        final again = await provisioner.provision(descriptor);
        expect(
          (again as ModelVerified).source,
          ModelVerificationSource.receipt,
          reason: 'a second provision must not re-download or re-hash',
        );
        expect(downloader.openCount, 1);
      },
    );

    test('a receipt from a different pin does not vouch for the file', () async {
      final descriptor = descriptorWith();
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(body: fixtureBytes),
      );
      await provisioner.provision(descriptor);

      // The pin moves (a new model revision) but the old file is still on disk.
      final repinned = descriptorWith(sha256Hex: wrongDigest);
      expect(await storage.statusOf(repinned), ModelInstallStatus.unverified);
    });

    test(
      'a malformed receipt degrades to unverified rather than throwing',
      () async {
        final descriptor = descriptorWith();
        await storage.prepare();
        await storage.installedFile(descriptor).writeAsBytes(fixtureBytes);
        await storage.receiptFile(descriptor).writeAsString('{not json');

        expect(
          await storage.statusOf(descriptor),
          ModelInstallStatus.unverified,
        );
        expect(await storage.readReceipt(descriptor), isNull);
      },
    );

    test('a file whose size drifted from its receipt is unverified', () async {
      final descriptor = descriptorWith();
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(body: fixtureBytes),
      );
      await provisioner.provision(descriptor);

      await storage.installedFile(descriptor).writeAsBytes([
        ...fixtureBytes,
        0x00,
      ]);
      expect(await storage.statusOf(descriptor), ModelInstallStatus.unverified);
    });

    test(
      'storage.prepare creates the directory and reports no-backup honestly',
      () async {
        expect(storage.root.existsSync(), isFalse);
        // The default exclusion is the no-op one, which never claims a marking it
        // did not apply.
        expect(await storage.prepare(), isFalse);
        expect(storage.root.existsSync(), isTrue);
      },
    );
  });
}

const _sourceUrl = 'https://example.invalid/gemma.litertlm';

/// A [ModelDownloader] that serves bytes from memory.
///
/// Scripts the three things that matter to the provisioner: the body, what the
/// server claims about its length, and how it fails.
class _ScriptedDownloader implements ModelDownloader {
  _ScriptedDownloader({
    required this.body,
    this.chunkSize = 64,
    this.failure,
    this.failAfterBytes,
    this.contentLengthOverride,
  });

  final Uint8List body;
  final int chunkSize;

  /// Thrown from [open] instead of returning a stream.
  final ModelDownloadException? failure;

  /// Fail the stream once this many bytes have been emitted.
  final int? failAfterBytes;

  /// Declared `Content-Length`; negative means "server declared none".
  final int? contentLengthOverride;

  int openCount = 0;
  Uri? lastUri;
  String? lastToken;

  @override
  Future<ModelByteStream> open(Uri uri, {String? authToken}) async {
    openCount++;
    lastUri = uri;
    lastToken = authToken;
    final scriptedFailure = failure;
    if (scriptedFailure != null) throw scriptedFailure;

    final declared = contentLengthOverride ?? body.length;
    return ModelByteStream(
      bytes: _emit(),
      contentLength: declared < 0 ? null : declared,
    );
  }

  Stream<List<int>> _emit() async* {
    var sent = 0;
    while (sent < body.length) {
      final end = (sent + chunkSize).clamp(0, body.length);
      yield body.sublist(sent, end);
      sent = end;
      final cutoff = failAfterBytes;
      if (cutoff != null && sent >= cutoff) {
        throw const SocketException.closed();
      }
    }
  }

  @override
  void close() {}
}
