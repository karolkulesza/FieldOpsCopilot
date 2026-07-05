import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
  /// hash-while-writing path a 2.6GB file uses.
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
      // Staging is cleaned up by the rename, so no half-file is left behind —
      // checked across every nonce, not just the bare `.part` path.
      expect(await _stagingLeftovers(storage, descriptor), isEmpty);
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
        expect(corrupt.origin, ModelByteOrigin.download);

        // Nothing installable survives: not the artifact, not the staging file,
        // and no receipt that a later download could inherit.
        expect(storage.installedFile(descriptor).existsSync(), isFalse);
        expect(await _stagingLeftovers(storage, descriptor), isEmpty);
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
        await storage.installDir(descriptor).create(recursive: true);
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
        // The point of the flow: no 2.6GB transfer over venue Wi-Fi.
        expect(downloader.openCount, 0);
        // And it is now cheap to answer on the next launch.
        expect(await storage.statusOf(descriptor), ModelInstallStatus.ready);
      },
    );

    test('a side-loaded file that does not match the pin is deleted', () async {
      final descriptor = descriptorWith();
      await storage.prepare();
      await storage.installDir(descriptor).create(recursive: true);
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
      expect(
        descriptorWith(sha256Hex: 'abc123').soleFile.hasPinnedHash,
        isFalse,
      );
      expect(
        descriptorWith(
          sha256Hex: fixtureDigest.toUpperCase(),
        ).soleFile.hasPinnedHash,
        isFalse,
        reason: 'callers normalize with ModelDescriptor.normalizeHash first',
      );
      expect(descriptorWith().soleFile.hasPinnedHash, isTrue);
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
      // Shipped Gemma catalog entries carry no URL and no hash: both are
      // deployment inputs, so the artifact is unprovisionable until they are
      // supplied.
      expect(base.soleFile.downloadUri, isNull);
      expect(base.soleFile.hasPinnedHash, isFalse);
      expect(base.configurationIssue, ModelConfigurationIssue.missingSource);

      final resolved = ModelCatalog.resolve(
        base,
        uri: 'https://example.invalid/gemma.litertlm',
        sha256Hex: fixtureDigest.toUpperCase(),
      );
      expect(
        resolved.soleFile.downloadUri,
        Uri.parse('https://example.invalid/gemma.litertlm'),
      );
      expect(resolved.soleFile.sha256Hex, fixtureDigest);
      expect(resolved.configurationIssue, isNull);
      // Identity and layout survive the overlay.
      expect(resolved.id, base.id);
      expect(resolved.soleFile.fileName, base.soleFile.fileName);
    });
  });

  group('concurrency', () {
    // Regression for R0-F1. Before the fix, two overlapping provision() calls
    // shared one `.part` path; because rename preserves the inode, the losing
    // transfer's still-open sink kept writing into the artifact the winner had
    // just installed. The result was `ModelVerified` + `ready` for bytes whose
    // digest nothing had ever checked.
    test('two overlapping provisions never install unhashed bytes', () async {
      final descriptor = descriptorWith();
      final downloader = _ScriptedDownloader(
        body: fixtureBytes,
        // A second transfer would serve something else entirely, so any byte of
        // it reaching the installed file is detectable.
        laterBodies: [Uint8List.fromList(utf8.encode('EVIL-WEIGHTS-' * 100))],
        chunkSize: 64,
        chunkDelay: const Duration(milliseconds: 1),
      );
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: downloader,
      );

      final results = await Future.wait([
        provisioner.provision(descriptor),
        provisioner.provision(descriptor),
      ]);

      // Neither call threw, and both report a verified install.
      expect(results, everyElement(isA<ModelVerified>()));
      // The installed bytes are the ones that were hashed.
      final installed = storage.installedFile(descriptor);
      expect(
        sha256.convert(await installed.readAsBytes()).toString(),
        fixtureDigest,
      );
      expect(await storage.statusOf(descriptor), ModelInstallStatus.ready);
      // Serialised, so the second caller found the first one's work done rather
      // than starting a redundant 2.6GB transfer.
      expect(downloader.openCount, 1);
      expect(
        (results[1] as ModelVerified).source,
        ModelVerificationSource.receipt,
      );
      expect(await _stagingLeftovers(storage, descriptor), isEmpty);
    });

    test(
      'a verify overlapping a provision does not read half-installed bytes',
      () async {
        final descriptor = descriptorWith();
        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(
            body: fixtureBytes,
            chunkSize: 64,
            chunkDelay: const Duration(milliseconds: 1),
          ),
        );

        final results = await Future.wait([
          provisioner.provision(descriptor),
          provisioner.verifyInstalled(descriptor),
        ]);

        expect(results.first, isA<ModelVerified>());
        // The verify either ran before the install (nothing there) or after it
        // (verified) — never on a file being renamed underneath it.
        expect(
          results.last,
          anyOf(isA<ModelAbsent>(), isA<ModelVerified>()),
          reason: 'a torn read would surface as ModelCorrupt',
        );
        expect(
          sha256
              .convert(await storage.installedFile(descriptor).readAsBytes())
              .toString(),
          fixtureDigest,
        );
      },
    );

    test('each transfer stages under its own name', () async {
      final descriptor = descriptorWith();
      // Two provisioners share the directory but not the queue, so both really do
      // transfer at once — the case the per-transfer staging name exists for.
      //
      // The second body differs from the first but is *exactly the same length*,
      // deliberately: sharing one staging path means two sinks writing the same
      // byte offsets, so every offset a slower transfer reaches would overwrite
      // the faster one's content in place. Identical bodies would make that
      // corruption invisible — the interleaved file would still hash correctly,
      // and this test would pass while proving nothing.
      final decoyBytes = Uint8List.fromList(
        utf8.encode('X' * fixtureBytes.length),
      );
      expect(decoyBytes.length, fixtureBytes.length);

      // The pin-matching transfer is the *faster* one, deliberately. That is the
      // order that reproduces the original corruption: it finishes, renames its
      // staging file into place, and — with a shared staging path, since rename
      // preserves the inode — the slower decoy's still-open sink keeps writing
      // into the installed artifact. The winner's digest then describes bytes that
      // are no longer on disk.
      final first = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(
          body: fixtureBytes,
          chunkSize: 64,
          chunkDelay: const Duration(milliseconds: 1),
        ),
      );
      final second = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(
          body: decoyBytes,
          chunkSize: 64,
          chunkDelay: const Duration(milliseconds: 3),
        ),
      );

      final results = await Future.wait([
        first.provision(descriptor),
        second.provision(descriptor),
      ]);

      // Every outcome arrives through the sealed result type; a losing rename in
      // particular must never throw out of provision().
      expect(
        results,
        everyElement(
          anyOf(
            isA<ModelVerified>(),
            isA<ModelDownloadFailed>(),
            isA<ModelCorrupt>(),
          ),
        ),
      );

      // The invariant that matters, asserted unconditionally: a ModelVerified is
      // a claim about bytes on disk, so it must still hold once *both* transfers
      // have finished. Guarding this behind "if the artifact exists" would let the
      // variant where nothing ends up installed pass while proving nothing.
      final verified = results.whereType<ModelVerified>().toList();
      expect(
        verified,
        isNotEmpty,
        reason: 'the transfer serving the pinned bytes must succeed',
      );
      for (final result in verified) {
        expect(result.sha256Hex, fixtureDigest);
        expect(result.file.existsSync(), isTrue);
        expect(
          sha256.convert(await result.file.readAsBytes()).toString(),
          fixtureDigest,
          reason:
              'a shared staging path lets the decoy keep writing into the '
              'artifact the winner just reported as verified',
        );
      }
      // And readiness must describe those same bytes.
      expect(await storage.statusOf(descriptor), ModelInstallStatus.ready);
      expect(await _stagingLeftovers(storage, descriptor), isEmpty);
    });

    test('a rename that cannot complete is reported, not thrown', () async {
      final descriptor = descriptorWith();
      await storage.prepare();
      // A directory sitting where the artifact belongs makes the atomic rename
      // fail — the stand-in for a full disk or a permissions change.
      await Directory(
        storage.installedFile(descriptor).path,
      ).create(recursive: true);

      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(body: fixtureBytes),
      );

      final result = await provisioner.provision(descriptor);

      expect(result, isA<ModelDownloadFailed>());
      expect(
        (result as ModelDownloadFailed).message,
        contains('install failed'),
      );
      // No staging file abandoned behind the failure.
      expect(await _stagingLeftovers(storage, descriptor), isEmpty);
    });
  });

  group('staging names', () {
    // Regression for R1-F1. The first version of the nonce was `pid` plus a
    // static counter, and static state is per-isolate while `pid` is process-wide
    // — so two isolates both produced `<pid>-0`, shared a staging path, and
    // brought R0-F1's corruption back in full. Task 1.8 runs inference on an
    // isolate and is also what will call provision().
    test('nonces do not collide across isolates', () async {
      const perIsolate = 32;

      final here = _nonceBatch(perIsolate);
      // A genuinely separate isolate: its copy of every `static` starts fresh.
      final there = await Isolate.run(() => _nonceBatch(perIsolate));

      expect(here, hasLength(perIsolate));
      expect(there, hasLength(perIsolate));
      expect(
        here.toSet().intersection(there.toSet()),
        isEmpty,
        reason: 'two isolates must never stage under the same name',
      );
      // Nor within one isolate.
      expect(here.toSet(), hasLength(perIsolate));
      expect(there.toSet(), hasLength(perIsolate));
    });

    // The isolate test above binds the *original* defect — a plain counter — but
    // not the claim `stagingNonce()`'s doc makes about *why* the replacement is
    // safe. Measured, by replacing only the random component with a constant and
    // keeping pid and microseconds:
    //
    //   run alone (--plain-name):   isolate test passes 5/5   this test fails 3/3
    //   run with the whole file:    isolate test fails 5/5    this test fails 5/5
    //
    // So the isolate test is not simply insensitive to a timestamp-only scheme, it
    // is *unreliably* sensitive — and the deciding factor is how warm
    // `stagingNonce()` is. Cold, each call takes at least a microsecond, so 32
    // sequential calls get 32 distinct timestamps and the two isolates' batches stay
    // disjoint; warm, several calls land in the same microsecond and duplicates
    // appear within one batch. An order-dependent binding is worse than an absent
    // one, because it fails in CI on some unrelated future change and sends someone
    // hunting a phantom.
    //
    // A pid+microseconds scheme really does collide when two isolates start
    // provisioning in the same microsecond, which is exactly the overlap this nonce
    // exists for, and the timestamp is the component a later simplification would
    // keep. Hence a separate assertion that fails deterministically in both run
    // conditions.
    test('the random component is what carries uniqueness', () {
      final trailing = List.generate(
        32,
        (_) => ModelProvisioner.stagingNonce().split('-').last,
      ).toSet();

      expect(
        trailing.length,
        greaterThan(1),
        reason:
            'pid and the timestamp are log readability only; a constant '
            'trailing field lets two isolates sharing a microsecond collide',
      );
    });

    test('a nonce is a filesystem-safe path component', () {
      final nonce = ModelProvisioner.stagingNonce();
      expect(nonce, matches(RegExp(r'^[0-9]+-[0-9]+-[0-9]+$')));
      // It becomes part of a file name, so a separator would silently write
      // outside the models directory.
      expect(nonce, isNot(contains('/')));
    });
  });

  group('replacing an artifact whose pin moved', () {
    // Regression for R0-F3: one provision() call used to hash the stale file,
    // delete it, and return ModelCorrupt without ever contacting the source — so
    // a device went from "working old model" to "no model" in a single call.
    test(
      'a single call fetches the replacement after the local copy fails',
      () async {
        final oldBytes = fixtureBytes;
        final newBytes = Uint8List.fromList(utf8.encode('rev-2 weights ' * 60));
        final newDigest = sha256.convert(newBytes).toString();

        // The old artifact is installed and verified under the old pin.
        final oldDescriptor = descriptorWith();
        final firstRun = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(body: oldBytes),
        );
        expect(await firstRun.provision(oldDescriptor), isA<ModelVerified>());

        // The build's pin now names a new revision, served at the same path.
        final newDescriptor = descriptorWith(sha256Hex: newDigest);
        final upgrade = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(body: newBytes),
        );

        final result = await upgrade.provision(newDescriptor);

        expect(result, isA<ModelVerified>());
        expect(
          (result as ModelVerified).source,
          ModelVerificationSource.download,
          reason: 'the replacement must be fetched in the same call',
        );
        expect(
          await storage.installedFile(newDescriptor).readAsBytes(),
          newBytes,
        );
        expect(await storage.statusOf(newDescriptor), ModelInstallStatus.ready);
      },
    );

    test(
      'a failed replacement leaves the old weights on disk but unusable',
      () async {
        final oldDescriptor = descriptorWith();
        final firstRun = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(body: fixtureBytes),
        );
        expect(await firstRun.provision(oldDescriptor), isA<ModelVerified>());

        // Pin moves, but the device is offline / the host rejects us.
        final newDescriptor = descriptorWith(sha256Hex: wrongDigest);
        final offline = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(
            body: fixtureBytes,
            failure: const ModelDownloadException('offline', statusCode: 503),
          ),
        );

        final result = await offline.provision(newDescriptor);

        expect(result, isA<ModelDownloadFailed>());
        // The old artifact survives — a basement technician is not stripped of the
        // only weights on the device just because a pin moved.
        expect(storage.installedFile(oldDescriptor).existsSync(), isTrue);
        expect(
          await storage.installedFile(oldDescriptor).readAsBytes(),
          fixtureBytes,
        );
        // But nothing vouches for it under the new pin, so it is never loadable.
        expect(
          await storage.statusOf(newDescriptor),
          ModelInstallStatus.unverified,
        );
        expect(storage.receiptFile(newDescriptor).existsSync(), isFalse);
      },
    );

    test(
      'replacement bytes that fail the pin are reported as fetched, not local',
      () async {
        final oldDescriptor = descriptorWith();
        final firstRun = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(body: fixtureBytes),
        );
        await firstRun.provision(oldDescriptor);

        final newDescriptor = descriptorWith(sha256Hex: wrongDigest);
        final upgrade = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(
            body: Uint8List.fromList(utf8.encode('wrong revision')),
          ),
        );

        final result = await upgrade.provision(newDescriptor);

        expect(result, isA<ModelCorrupt>());
        final corrupt = result as ModelCorrupt;
        // The distinction the caller needs: the URL and the hash disagree, rather
        // than a stale local file having failed.
        expect(corrupt.origin, ModelByteOrigin.download);
        expect(corrupt.quarantined, isTrue);
        expect(await _stagingLeftovers(storage, newDescriptor), isEmpty);
        // The old artifact is still there, still not loadable.
        expect(storage.installedFile(oldDescriptor).existsSync(), isTrue);
        expect(
          await storage.statusOf(newDescriptor),
          ModelInstallStatus.unverified,
        );
      },
    );

    test(
      'verifyInstalled still quarantines, since nothing will replace it',
      () async {
        final descriptor = descriptorWith();
        await storage.prepare();
        await storage.installDir(descriptor).create(recursive: true);
        await storage
            .installedFile(descriptor)
            .writeAsBytes(utf8.encode('rotted bytes'));

        final result = await ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(body: fixtureBytes),
        ).verifyInstalled(descriptor);

        expect(result, isA<ModelCorrupt>());
        final corrupt = result as ModelCorrupt;
        expect(corrupt.origin, ModelByteOrigin.installedFile);
        expect(corrupt.quarantined, isTrue);
        expect(storage.installedFile(descriptor).existsSync(), isFalse);
      },
    );
  });

  group('receipt hygiene', () {
    // Regression for R0-F4: the corrupt-download path deleted the staging file
    // but not the receipt, so a receipt could outlive its artifact and then bless
    // the next same-sized file to appear at that path.
    test(
      'a failed download clears a receipt left over from a deleted artifact',
      () async {
        final descriptor = descriptorWith();
        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(
            body: fixtureBytes,
            // Second call serves bytes that do not match the pin.
            laterBodies: [Uint8List.fromList(utf8.encode('junk'))],
          ),
        );
        await provisioner.provision(descriptor);
        expect(storage.receiptFile(descriptor).existsSync(), isTrue);

        // The multi-gigabyte artifact is removed by hand to free space; the small
        // receipt is easy to leave behind.
        await storage.installedFile(descriptor).delete();

        final result = await provisioner.provision(descriptor);
        expect(result, isA<ModelCorrupt>());
        expect(
          storage.receiptFile(descriptor).existsSync(),
          isFalse,
          reason: 'a receipt must not survive a failed verification',
        );

        // Now a same-sized file nobody hashed appears at that path. Without the
        // receipt cleanup it would report `ready`.
        await storage
            .installedFile(descriptor)
            .writeAsBytes(
              Uint8List.fromList(fixtureBytes)..[0] = fixtureBytes[0] ^ 0xFF,
            );
        expect(
          await storage.statusOf(descriptor),
          ModelInstallStatus.unverified,
        );
      },
    );

    test(
      'a receipt naming a different model does not vouch for the file',
      () async {
        final descriptor = descriptorWith();
        await storage.prepare();
        await storage.installDir(descriptor).create(recursive: true);
        await storage.installedFile(descriptor).writeAsBytes(fixtureBytes);
        // Same digest and size, different model id — e.g. a renamed catalog entry.
        await storage
            .receiptFile(descriptor)
            .writeAsString(
              '{"modelId":"some-other-model","sha256":"$fixtureDigest",'
              '"sizeBytes":${fixtureBytes.length}}',
            );

        expect(
          await storage.statusOf(descriptor),
          ModelInstallStatus.unverified,
        );
      },
    );
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
      expect(await _stagingLeftovers(storage, descriptor), isEmpty);
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
        expect(await _stagingLeftovers(storage, descriptor), isEmpty);
      },
    );

    test('a body longer than Content-Length is named as over-long', () async {
      final descriptor = descriptorWith();
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: _ScriptedDownloader(
          body: fixtureBytes,
          // Server under-declares — the mirror image of a truncation, and a real
          // symptom of a transport that re-encoded the body.
          contentLengthOverride: fixtureBytes.length - 100,
        ),
      );

      final result = await provisioner.provision(descriptor);

      expect(result, isA<ModelDownloadFailed>());
      expect(
        (result as ModelDownloadFailed).message,
        contains('over-long transfer'),
        reason:
            'calling an over-long body "truncated" sends the operator the '
            'wrong way',
      );
      expect(await _stagingLeftovers(storage, descriptor), isEmpty);
    });

    test(
      'staging files abandoned by an interrupted run are swept, not accumulated',
      () async {
        final descriptor = descriptorWith();
        await storage.prepare();
        // What a killed process leaves behind: a partial staging directory
        // under the bare suffix (an older build) and under a nonce (this one).
        // Neither carries resumable state.
        await storage.stagingDir(descriptor).create(recursive: true);
        await File(
          '${storage.stagingDir(descriptor).path}/partial.litertlm',
        ).writeAsBytes(utf8.encode('leftover partial body'));
        await storage.stagingDir(descriptor, nonce: '999-0').create();
        await File(
          '${storage.stagingDir(descriptor, nonce: '999-0').path}/w.litertlm',
        ).writeAsBytes(utf8.encode('another abandoned transfer'));
        expect(await _stagingLeftovers(storage, descriptor), hasLength(2));

        final provisioner = ModelProvisioner(
          storage: storage,
          downloader: _ScriptedDownloader(body: fixtureBytes),
        );

        // The install is unaffected by the leftovers…
        expect(await provisioner.provision(descriptor), isA<ModelVerified>());
        expect(
          await storage.installedFile(descriptor).readAsBytes(),
          fixtureBytes,
        );
        // …and they are gone, rather than a half-downloaded 2.6GB file sitting on
        // a rugged device forever.
        expect(
          await _stagingLeftovers(storage, descriptor),
          isEmpty,
          reason: 'abandoned transfers must be swept',
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
        await storage.installDir(descriptor).create(recursive: true);
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
        await storage.installDir(descriptor).create(recursive: true);
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

/// Generates [count] staging nonces.
///
/// A top-level function so it can be sent to another isolate, which is the whole
/// point: the isolate gets its own copy of every `static` in the library.
List<String> _nonceBatch(int count) =>
    List.generate(count, (_) => ModelProvisioner.stagingNonce());

/// Every staging directory left in the models root for [descriptor], whatever
/// its nonce.
///
/// Asserting on `storage.stagingDir(descriptor)` alone would be checking a path
/// nothing writes any more — transfers stage under `.part.<nonce>` — which is
/// exactly the "green for an unrelated reason" trap.
Future<List<String>> _stagingLeftovers(
  ModelStorage storage,
  ModelDescriptor descriptor,
) async {
  if (!await storage.root.exists()) return const [];
  final prefix = '${descriptor.id}${ModelStorage.stagingSuffix}';
  return storage.root
      .listSync()
      .whereType<Directory>()
      .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
      .where((name) => name.startsWith(prefix))
      .toList();
}

/// A [ModelDownloader] that serves bytes from memory.
///
/// Scripts the things that matter to the provisioner: the body (which may differ
/// per call, so concurrent transfers can be told apart), what the server claims
/// about its length, how slowly it arrives, and how it fails.
class _ScriptedDownloader implements ModelDownloader {
  _ScriptedDownloader({
    required this.body,
    this.laterBodies = const [],
    this.chunkSize = 64,
    this.chunkDelay,
    this.failure,
    this.failAfterBytes,
    this.contentLengthOverride,
  });

  final Uint8List body;

  /// Bodies served by the 2nd, 3rd, … call to [open]; the last one repeats.
  final List<Uint8List> laterBodies;

  final int chunkSize;

  /// Yields between chunks, so two overlapping transfers genuinely interleave
  /// instead of one running to completion inside a single microtask drain.
  final Duration? chunkDelay;

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
    final index = openCount++;
    lastUri = uri;
    lastToken = authToken;
    final scriptedFailure = failure;
    if (scriptedFailure != null) throw scriptedFailure;

    final served = _bodyFor(index);
    final declared = contentLengthOverride ?? served.length;
    return ModelByteStream(
      bytes: _emit(served),
      contentLength: declared < 0 ? null : declared,
    );
  }

  Uint8List _bodyFor(int index) {
    if (index == 0 || laterBodies.isEmpty) return body;
    final i = index - 1;
    return i < laterBodies.length ? laterBodies[i] : laterBodies.last;
  }

  Stream<List<int>> _emit(Uint8List served) async* {
    var sent = 0;
    while (sent < served.length) {
      final delay = chunkDelay;
      if (delay != null) await Future<void>.delayed(delay);
      final end = (sent + chunkSize).clamp(0, served.length);
      yield served.sublist(sent, end);
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
