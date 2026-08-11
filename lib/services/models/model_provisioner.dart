import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'model_descriptor.dart';
import 'model_downloader.dart';
import 'model_storage.dart';

/// Which stage of provisioning a progress report belongs to.
enum ModelProvisionPhase {
  /// Bytes are arriving from the network.
  downloading,

  /// Bytes already on disk are being hashed.
  verifying,
}

/// A progress sample from a provisioning run.
///
/// [processedBytes] and [totalBytes] are aggregated **across the whole file
/// set** — the UI's bar describes the model, not whichever file happens to be in
/// flight. [fileIndex]/[fileCount] say which file that is, so a multi-file
/// download can be labelled "file 2 of 4" without a second callback shape.
class ModelProvisionProgress {
  const ModelProvisionProgress({
    required this.phase,
    required this.processedBytes,
    this.totalBytes,
    this.fileIndex = 1,
    this.fileCount = 1,
  });

  final ModelProvisionPhase phase;

  /// Bytes finished so far across the set: every completed file plus the bytes
  /// of the file in flight.
  final int processedBytes;

  /// Expected total for the set, or `null` when it is genuinely unknown for any
  /// file (a server that declared no `Content-Length` and a descriptor with no
  /// documented size — one such file makes the whole total a guess).
  final int? totalBytes;

  /// 1-based position of the file in flight within the set.
  final int fileIndex;

  /// Number of files in the set.
  final int fileCount;

  /// Completed share of the phase in `0.0..1.0`, or `null` when [totalBytes] is
  /// unknown — the UI then shows an indeterminate indicator rather than a
  /// fabricated percentage.
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (processedBytes / total).clamp(0.0, 1.0);
  }

  @override
  String toString() =>
      'ModelProvisionProgress(${phase.name}, $processedBytes/$totalBytes, '
      'file $fileIndex/$fileCount)';
}

/// Reports provisioning progress. Called synchronously, once per chunk.
typedef ModelProvisionProgressCallback =
    void Function(ModelProvisionProgress progress);

/// Outcome of a provisioning or verification run.
sealed class ModelProvisionResult {
  const ModelProvisionResult();
}

/// How a [ModelVerified] result established its integrity.
enum ModelVerificationSource {
  /// Receipts from an earlier verification vouched for every file.
  receipt,

  /// Files that were already on disk were hashed now (side-loaded weights, or an
  /// install whose receipt was missing).
  existingFile,

  /// The bytes were downloaded and hashed during this run.
  download,
}

/// One installed, verified file of a model.
final class VerifiedArtifact {
  const VerifiedArtifact({
    required this.fileName,
    required this.file,
    required this.sha256Hex,
    required this.sizeBytes,
  });

  final String fileName;
  final File file;
  final String sha256Hex;
  final int sizeBytes;
}

/// Every file of the model is installed and hashes to its pinned digest.
final class ModelVerified extends ModelProvisionResult {
  const ModelVerified({
    required this.artifacts,
    required this.source,
    required this.excludedFromBackup,
  });

  /// One entry per file of the set, in descriptor order.
  final List<VerifiedArtifact> artifacts;

  final ModelVerificationSource source;

  /// Whether the storage directory is genuinely marked no-backup. Reported
  /// rather than assumed, so the app never claims a platform guarantee it did not
  /// obtain.
  final bool excludedFromBackup;

  /// Total installed size across the set.
  int get sizeBytes =>
      artifacts.fold(0, (total, artifact) => total + artifact.sizeBytes);

  /// The one artifact of a single-file model — the LLM call sites. Throws
  /// [StateError] on a multi-file result rather than guessing which file the
  /// caller meant.
  VerifiedArtifact get soleArtifact => artifacts.single;

  /// [soleArtifact]'s installed file. Single-file models only.
  File get file => soleArtifact.file;

  /// [soleArtifact]'s digest. Single-file models only.
  String get sha256Hex => soleArtifact.sha256Hex;
}

/// Which bytes a result is about.
enum ModelByteOrigin {
  /// A file that was already on disk — most often an artifact whose pin has moved
  /// to a newer revision, or a side-load. The source was never contacted.
  installedFile,

  /// Bytes fetched during this run.
  download,
}

/// Bytes were obtained but do not hash to the pinned digest.
///
/// Names the offending [fileName], because a set fails one file at a time and
/// "the model is corrupt" would send the operator hashing four files to find the
/// one this code already knows.
///
/// [origin] matters to whoever reads this: bytes *fetched* and failing the pin
/// means the URL and hash disagree, while an *installed file* failing it usually
/// means the pin moved and the old artifact is still there.
final class ModelCorrupt extends ModelProvisionResult {
  const ModelCorrupt({
    required this.fileName,
    required this.expectedSha256Hex,
    required this.actualSha256Hex,
    required this.sizeBytes,
    required this.origin,
    required this.quarantined,
  });

  /// The file whose bytes failed the pin.
  final String fileName;

  final String expectedSha256Hex;
  final String actualSha256Hex;
  final int sizeBytes;
  final ModelByteOrigin origin;

  /// Whether the offending bytes were removed.
  ///
  /// `false` is not a failure report: a `provision()` whose replacement download
  /// did not verify deliberately leaves an existing artifact in place rather than
  /// stripping an offline device of the only weights it has. It is never
  /// *loadable* — no receipt vouches for it, so readiness stays `unverified` — it
  /// is merely still on disk.
  final bool quarantined;
}

/// A file could not be fetched at all — transport error or an HTTP status
/// that is not `200`.
final class ModelDownloadFailed extends ModelProvisionResult {
  const ModelDownloadFailed({
    required this.message,
    this.statusCode,
    this.fileName,
  });

  final String message;
  final int? statusCode;

  /// The file whose transfer failed, when the failure is attributable to one.
  final String? fileName;
}

/// Provisioning was refused because the build carries no usable source or no
/// pinned hash for at least one file. Never a network or disk failure — always
/// a configuration one.
final class ModelNotConfigured extends ModelProvisionResult {
  const ModelNotConfigured({required this.issue, required this.descriptor});

  final ModelConfigurationIssue issue;
  final ModelDescriptor descriptor;
}

/// The set is not fully installed — at least one required file is missing. Only
/// returned by [ModelProvisioner.verifyInstalled], which checks what is there
/// rather than fetching what is not; `provision()` is the operation that
/// completes an incomplete set.
final class ModelAbsent extends ModelProvisionResult {
  const ModelAbsent();
}

/// Downloads, verifies and installs on-device model weights — one file or a
/// set, all-or-nothing either way.
///
/// The order of operations is the whole point of this class:
///
/// 1. every file streams to a per-transfer `<id>.part.<nonce>/` staging
///    directory, never to the final path;
/// 2. each file's SHA-256 is computed **during** its stream, so a 2.6GB artifact
///    is neither buffered in memory nor read twice;
/// 3. only after **every** file's digest matches its pin does anything move: the
///    staged files are renamed into the install directory one by one, each an
///    atomic replace, and each earns its receipt as it lands;
/// 4. fetched bytes that fail are deleted, and operations on one model are
///    serialised so two callers cannot interleave into each other's files.
///
/// That sequence is what makes "the model is ready" a claim about verified bytes
/// rather than about files that happen to exist — and it is why a transfer that
/// dies on file 3 of 4 installs *nothing*, leaving whatever was installed before
/// untouched (TC-PROV-SET-02). The rename pass does mean a crash *between two
/// renames* can leave a mixed set on disk; that is not a lying state — the new
/// files have no receipts yet, so the set reads `unverified`, and the next
/// provision re-hashes in place — and if any file fails that hash, re-fetches
/// the **whole set**, not just the hole. No per-file download skip exists;
/// deliberate at this artifact size (43.65MB), and recorded here so the doc
/// matches the code rather than a nicer design (R0-F4).
///
/// It is also the client half of the OTA-model-delivery design in the README:
/// the server half (bucket layout, device-capability-based selection, staged
/// rollout) is narrated, not built.
class ModelProvisioner {
  ModelProvisioner({
    required this._storage,
    ModelDownloader? downloader,
    this._authToken,
  }) : _downloader = downloader ?? HttpModelDownloader();

  final ModelStorage _storage;
  final ModelDownloader _downloader;
  final String? _authToken;

  /// Tail of the queue of operations per model id — see [_serialized].
  final Map<String, Future<void>> _queues = {};

  /// Source of the random component of a staging name.
  ///
  /// Being per-isolate is fine *because* it is seeded from OS entropy — unlike a
  /// counter, two isolates do not both start at zero. See [stagingNonce].
  static final Random _stagingRandom = Random.secure();

  /// A staging-name component unique across every writer that could share the
  /// models directory.
  ///
  /// The first version of this was `pid` plus a static counter, which was wrong in
  /// a way worth recording: **static state is per-isolate while `pid` is
  /// process-wide**, so two isolates in one process both produce
  /// `<pid>-0` — the shared staging path whose consequences this whole design
  /// exists to prevent (inode-preserving `rename` lets the loser's open sink write
  /// into the installed artifact). Nothing in `lib/` runs on an isolate today, but
  /// Task 1.8 puts inference on one and is also the task that will call
  /// `provision()`.
  ///
  /// Dart has no `O_EXCL` file creation, so uniqueness cannot be *enforced* by the
  /// filesystem; it is made overwhelmingly likely instead. The pid and timestamp
  /// are kept for log readability, and the 32 random bits are what actually carry
  /// the guarantee.
  @visibleForTesting
  static String stagingNonce() =>
      '$pid-${DateTime.now().microsecondsSinceEpoch}-'
      '${_stagingRandom.nextInt(1 << 32)}';

  /// The current install state of [descriptor], answered from the receipts
  /// without hashing — cheap enough for a startup path and for the UI's
  /// "model ready" indicator.
  Future<ModelInstallStatus> statusOf(ModelDescriptor descriptor) =>
      _storage.statusOf(descriptor);

  /// Ensures verified weights for [descriptor] are installed, downloading them
  /// when what is on disk does not satisfy the pinned hashes.
  ///
  /// Idempotent: with valid receipts in place it does no I/O beyond the status
  /// check, so calling it on every launch is fine. Side-loaded weights (copied
  /// onto the device by hand for a demo) are hashed in place instead of being
  /// re-downloaded — and only if that hash *fails* is a download started, which is
  /// also the ordinary model-upgrade path when a pin moves to a new revision.
  ///
  /// Calls for the same model are **serialised** (see [_serialized]); overlapping
  /// callers do not race, and the second one usually finds the first one's result
  /// already installed. Two *different* models do not queue behind each other —
  /// the queue is per id — which is what lets the STT set download while the LLM
  /// verifies.
  Future<ModelProvisionResult> provision(
    ModelDescriptor descriptor, {
    ModelProvisionProgressCallback? onProgress,
  }) {
    final issue = descriptor.configurationIssue;
    if (issue != null) {
      return Future.value(
        ModelNotConfigured(issue: issue, descriptor: descriptor),
      );
    }
    return _serialized(
      descriptor,
      () => _provision(descriptor, onProgress: onProgress),
    );
  }

  Future<ModelProvisionResult> _provision(
    ModelDescriptor descriptor, {
    ModelProvisionProgressCallback? onProgress,
  }) async {
    final excludedFromBackup = await _storage.prepare();
    final status = await _storage.statusOf(descriptor);

    switch (status) {
      case ModelInstallStatus.ready:
        return ModelVerified(
          artifacts: [
            for (final file in descriptor.files)
              VerifiedArtifact(
                fileName: file.fileName,
                file: _storage.installedFile(descriptor, file),
                sha256Hex: file.sha256Hex,
                sizeBytes: await _storage
                    .installedFile(descriptor, file)
                    .length(),
              ),
          ],
          source: ModelVerificationSource.receipt,
          excludedFromBackup: excludedFromBackup,
        );

      case ModelInstallStatus.unverified:
        // Hash what is already there first — a side-loaded artifact must not
        // trigger a 2.6GB download just because it arrived without a receipt.
        final local = await _verifyExisting(
          descriptor,
          excludedFromBackup: excludedFromBackup,
          // Deliberately *not* quarantined yet: the usual reason a local file
          // fails the current pin is that the pin moved to a new revision, and
          // deleting the working old weights before the replacement exists would
          // strip an offline device of the only model it has. The download below
          // replaces them by atomic rename if and only if the new bytes verify.
          quarantineOnMismatch: false,
          onProgress: onProgress,
        );
        if (local is ModelVerified) return local;
        return _downloadAndInstall(
          descriptor,
          excludedFromBackup: excludedFromBackup,
          onProgress: onProgress,
        );

      case ModelInstallStatus.absent:
        return _downloadAndInstall(
          descriptor,
          excludedFromBackup: excludedFromBackup,
          onProgress: onProgress,
        );
    }
  }

  /// Runs [body] after every operation already queued for this model id.
  ///
  /// Two overlapping `provision()` calls used to corrupt the install outright:
  /// they shared one staging path, and because POSIX `rename` preserves the inode,
  /// the loser's still-open sink went on writing into the artifact the winner had
  /// just installed — so the digest that earned the rename described bytes that
  /// were no longer on disk, and `statusOf` reported `ready` for them. Unique
  /// staging names (see [ModelStorage.stagingDir]) make that impossible; this
  /// queue additionally stops the redundant work, so the second caller simply sees
  /// the first one's verified install.
  ///
  /// Scope, stated honestly: this serialises callers of *this instance*, and an
  /// instance cannot span isolates or processes. The app has exactly one, from
  /// `modelProvisionerProvider`. Any two provisioners that do **not** share this
  /// queue — a second isolate as much as a second process — still interleave. That
  /// is no longer a *corrupting* interleave, because [stagingNonce] makes their
  /// staging paths disjoint and each transfer hashes and renames its own complete
  /// files; what remains is that a surviving receipt could describe the other
  /// run's artifact, if the two runs pinned different hashes and their bodies
  /// happened to be the same length. A lock file shared through the filesystem is
  /// the fix if that ever becomes real.
  Future<ModelProvisionResult> _serialized(
    ModelDescriptor descriptor,
    Future<ModelProvisionResult> Function() body,
  ) {
    final key = descriptor.id;
    final predecessor = _queues[key] ?? Future<void>.value();
    final release = Completer<void>();
    // The queue tail never completes with an error, so a failed operation cannot
    // poison the ones behind it.
    _queues[key] = release.future;

    return predecessor.then((_) => body()).whenComplete(() {
      if (_queues[key] == release.future) _queues.remove(key);
      release.complete();
    });
  }

  /// Re-hashes every installed file, ignoring any receipt.
  ///
  /// This is the explicit integrity check — a receipt is a cache, and a cache
  /// cannot detect bytes that rotted after it was written (a truncated copy, a
  /// failing flash cell). Returns [ModelAbsent] when any required file is
  /// missing, and quarantines an offending file on mismatch exactly as a fresh
  /// download would.
  Future<ModelProvisionResult> verifyInstalled(
    ModelDescriptor descriptor, {
    ModelProvisionProgressCallback? onProgress,
  }) {
    // A source URL is irrelevant here — nothing is fetched — but the pinned
    // hashes are the entire operation.
    if (descriptor.files.any((file) => !file.hasPinnedHash)) {
      return Future.value(
        ModelNotConfigured(
          issue: ModelConfigurationIssue.unpinnedHash,
          descriptor: descriptor,
        ),
      );
    }
    // Same queue as [provision]: hashing a file while a download is renaming over
    // it would report on bytes that no longer exist.
    return _serialized(descriptor, () async {
      final excludedFromBackup = await _storage.prepare();
      // `prepare` before the existence check, not after: `statusOf` (via
      // `_storage`) also runs the legacy-layout migration, and checking a path
      // the migration is about to populate would report absence over presence.
      if (await _storage.statusOf(descriptor) == ModelInstallStatus.absent) {
        return const ModelAbsent();
      }
      return _verifyExisting(
        descriptor,
        excludedFromBackup: excludedFromBackup,
        // The explicit check *is* the operation, so a mismatch is quarantined
        // here: there is no replacement download coming that might need the old
        // bytes kept.
        quarantineOnMismatch: true,
        onProgress: onProgress,
      );
    });
  }

  /// Releases the downloader's transport resources.
  void dispose() => _downloader.close();

  /// Hashes every file already on disk and files a receipt for each, or reports
  /// [ModelCorrupt] for the first file whose digest does not match.
  ///
  /// Receipts are written file-by-file as each verifies, so a set that fails on
  /// its last file keeps the verifications it earned — the next pass re-hashes
  /// only what is still unvouched.
  ///
  /// [quarantineOnMismatch] decides whether an offending file is deleted. Its
  /// stale receipt is dropped either way: whatever it once vouched for, it does
  /// not vouch for a file that just failed the pin.
  Future<ModelProvisionResult> _verifyExisting(
    ModelDescriptor descriptor, {
    required bool excludedFromBackup,
    required bool quarantineOnMismatch,
    ModelProvisionProgressCallback? onProgress,
  }) async {
    final files = descriptor.files;
    final lengths = [
      for (final file in files)
        await _storage.installedFile(descriptor, file).length(),
    ];
    final totalBytes = lengths.fold(0, (a, b) => a + b);
    var completedBytes = 0;

    final artifacts = <VerifiedArtifact>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final installed = _storage.installedFile(descriptor, file);

      final digest = await _hashFile(
        installed,
        onBytes: (processed) => onProgress?.call(
          ModelProvisionProgress(
            phase: ModelProvisionPhase.verifying,
            processedBytes: completedBytes + processed,
            totalBytes: totalBytes,
            fileIndex: i + 1,
            fileCount: files.length,
          ),
        ),
      );
      completedBytes += lengths[i];

      if (digest != file.sha256Hex) {
        final quarantined =
            quarantineOnMismatch && await _quarantineFile(descriptor, file);
        // Whatever this file's receipt once described, it does not describe a
        // file that just failed the pin. The set-mates that already verified
        // keep theirs.
        await _dropStaleReceipts(descriptor);
        return ModelCorrupt(
          fileName: file.fileName,
          expectedSha256Hex: file.sha256Hex,
          actualSha256Hex: digest,
          sizeBytes: lengths[i],
          origin: ModelByteOrigin.installedFile,
          quarantined: quarantined,
        );
      }

      await _storage.writeReceipt(
        descriptor,
        file: file,
        sha256Hex: digest,
        sizeBytes: lengths[i],
      );
      artifacts.add(
        VerifiedArtifact(
          fileName: file.fileName,
          file: installed,
          sha256Hex: digest,
          sizeBytes: lengths[i],
        ),
      );
    }

    return ModelVerified(
      artifacts: artifacts,
      source: ModelVerificationSource.existingFile,
      excludedFromBackup: excludedFromBackup,
    );
  }

  /// Streams every file of the set to a staging directory while hashing it,
  /// then installs the set only if every digest matches.
  Future<ModelProvisionResult> _downloadAndInstall(
    ModelDescriptor descriptor, {
    required bool excludedFromBackup,
    ModelProvisionProgressCallback? onProgress,
  }) async {
    // A staging directory unique to this transfer, so no two transfers can ever
    // share a sink or delete each other's bytes — see [ModelStorage.stagingDir].
    final staging = _storage.stagingDir(descriptor, nonce: stagingNonce());
    // Leftovers from an interrupted run carry no resumable state, so they are
    // swept rather than accumulated (a half-written 2.6GB file is real disk
    // pressure). Ours is spared by name. Note this unlinks a staging directory
    // another writer may still be filling — POSIX allows that — which kills their
    // transfer at rename time rather than sparing it; see
    // [ModelStorage.deleteStagingDirs]. Harmless but not polite, and it cannot
    // happen between two callers of this instance, which the queue serialises.
    await _storage.deleteStagingDirs(descriptor, keep: staging);
    try {
      await staging.create(recursive: true);
    } on FileSystemException catch (error) {
      return ModelDownloadFailed(
        message:
            'install failed: could not create the staging directory '
            '(${error.osError?.message ?? error.message})',
      );
    }

    final files = descriptor.files;
    // Expected size per file, best knowledge first: the server's declared
    // `Content-Length` once its transfer opens, the documented size until then.
    // The set's total is the sum — and it is only a total at all when every
    // file has *some* expectation, otherwise the honest fraction is none.
    final expected = [for (final file in files) file.approximateSizeBytes];
    int? totalBytes() {
      var total = 0;
      for (final size in expected) {
        if (size == null) return null;
        total += size;
      }
      return total;
    }

    var completedBytes = 0;
    final staged = <({String fileName, String digest, int sizeBytes})>[];

    for (var i = 0; i < files.length; i++) {
      final file = files[i];

      final ModelByteStream source;
      try {
        source = await _downloader.open(
          file.downloadUri!,
          // Only where the descriptor says the token belongs — it was supplied
          // as a pair with the *configured* model's URI, and sending it to a
          // committed source's host would hand the credential to a third
          // party. See [ModelDescriptor.sendsAuthToken] (R0-F3).
          authToken: descriptor.sendsAuthToken ? _authToken : null,
        );
      } on ModelDownloadException catch (error) {
        await _deleteStaging(staging);
        return ModelDownloadFailed(
          message: '${file.fileName}: ${error.message}',
          statusCode: error.statusCode,
          fileName: file.fileName,
        );
      } on SocketException catch (error) {
        await _deleteStaging(staging);
        return ModelDownloadFailed(
          message: '${file.fileName}: network error: ${error.message}',
          fileName: file.fileName,
        );
      } on HttpException catch (error) {
        await _deleteStaging(staging);
        return ModelDownloadFailed(
          message: '${file.fileName}: http error: ${error.message}',
          fileName: file.fileName,
        );
      }

      final declaredTotal = source.contentLength;
      if (declaredTotal != null) expected[i] = declaredTotal;

      final collector = _DigestCollector();
      final hasher = sha256.startChunkedConversion(collector);
      var received = 0;
      final stagedFile = File('${staging.path}/${file.fileName}');

      try {
        final sink = stagedFile.openWrite();
        try {
          await for (final chunk in source.bytes) {
            sink.add(chunk);
            hasher.add(chunk);
            received += chunk.length;
            onProgress?.call(
              ModelProvisionProgress(
                phase: ModelProvisionPhase.downloading,
                processedBytes: completedBytes + received,
                totalBytes: totalBytes(),
                fileIndex: i + 1,
                fileCount: files.length,
              ),
            );
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
      } on Exception catch (error) {
        await _deleteStaging(staging);
        return ModelDownloadFailed(
          message: '${file.fileName}: transfer failed: $error',
          fileName: file.fileName,
        );
      }

      // A body that does not match the length the server declared is a transfer
      // fault, not corruption — naming it correctly keeps the operator from
      // re-checking a hash that was never the problem. Short and long are named
      // separately because they have different causes (a dropped connection versus
      // a mis-declared or transport-encoded body).
      if (declaredTotal != null && received != declaredTotal) {
        await _deleteStaging(staging);
        return ModelDownloadFailed(
          message: received < declaredTotal
              ? '${file.fileName}: truncated transfer: received $received of '
                    '$declaredTotal bytes'
              : '${file.fileName}: over-long transfer: received $received '
                    'bytes, server declared $declaredTotal',
          fileName: file.fileName,
        );
      }

      hasher.close();
      final digest = collector.digest.toString();

      if (digest != file.sha256Hex) {
        // The staging directory is the only thing to remove — artifacts already
        // installed at the target path are deliberately left alone, so a device
        // that cannot fetch a valid replacement is not stripped of the weights it
        // has. Stale receipts still go: they cannot vouch for anything now.
        final removed = await _deleteStaging(staging);
        await _dropStaleReceipts(descriptor);
        return ModelCorrupt(
          fileName: file.fileName,
          expectedSha256Hex: file.sha256Hex,
          actualSha256Hex: digest,
          sizeBytes: received,
          origin: ModelByteOrigin.download,
          quarantined: removed,
        );
      }

      expected[i] = received;
      completedBytes += received;
      staged.add((
        fileName: file.fileName,
        digest: digest,
        sizeBytes: received,
      ));
    }

    // Every file verified; only now does anything touch the install directory.
    // Each rename is an atomic replace of that file, and each file's receipt is
    // written as it lands — a crash mid-pass leaves new files without receipts,
    // which reads `unverified` and re-hashes cheaply, never `ready` over bytes
    // nothing vouched for.
    final artifacts = <VerifiedArtifact>[];
    try {
      await _storage.installDir(descriptor).create(recursive: true);
      for (var i = 0; i < files.length; i++) {
        final file = files[i];
        final installed = _storage.installedFile(descriptor, file);
        await File('${staging.path}/${file.fileName}').rename(installed.path);
        await _storage.writeReceipt(
          descriptor,
          file: file,
          sha256Hex: staged[i].digest,
          sizeBytes: staged[i].sizeBytes,
        );
        artifacts.add(
          VerifiedArtifact(
            fileName: file.fileName,
            file: installed,
            sha256Hex: staged[i].digest,
            sizeBytes: staged[i].sizeBytes,
          ),
        );
      }
    } on FileSystemException catch (error) {
      // Disk full, a permissions change, or another process having swept our
      // staging directory. Reported through the sealed result type rather than
      // thrown: `provision` promises a `ModelProvisionResult`, and a caller
      // forced to also catch `FileSystemException` is a caller that will forget
      // to. Receipts for files that did land were already written and are true;
      // the set as a whole reads `unverified` or `absent`, never `ready`.
      await _deleteStaging(staging);
      await _dropStaleReceipts(descriptor);
      return ModelDownloadFailed(
        message:
            'install failed: could not move the verified files into place '
            '(${error.osError?.message ?? error.message})',
      );
    }
    await _deleteStaging(staging);

    return ModelVerified(
      artifacts: artifacts,
      source: ModelVerificationSource.download,
      excludedFromBackup: excludedFromBackup,
    );
  }

  /// Removes receipts that no longer vouch for what is on disk.
  ///
  /// The unconditional version of this was too broad: a failed transfer would
  /// invalidate the receipt of an artifact it never touched — say a bad mirror
  /// serving junk while a good copy is already installed — forcing a needless
  /// re-hash of 2.6GB on the next launch. So the check is per file, "does a
  /// valid receipt describe this installed file right now?", which keeps the
  /// guarantee that mattered (a receipt must never outlive the bytes it
  /// describes, or it would bless the next same-sized file to appear at that
  /// path) without punishing an install that is genuinely fine.
  ///
  /// Failing to delete is not worth failing provisioning over, but it does leave a
  /// stale receipt behind, so it is logged rather than swallowed.
  Future<void> _dropStaleReceipts(ModelDescriptor descriptor) async {
    try {
      await _storage.deleteStaleReceipts(descriptor);
    } on FileSystemException catch (error) {
      debugPrint('could not remove stale model receipts: ${error.message}');
    }
  }

  /// Deletes one offending file (and, via the stale-receipt sweep its caller
  /// runs, its receipt), reporting whether the removal actually happened.
  ///
  /// Per file rather than per model on purpose: quarantining a whole set because
  /// one file failed would delete gigabytes of set-mates that verified fine.
  Future<bool> _quarantineFile(
    ModelDescriptor descriptor,
    ModelArtifactFile file,
  ) async {
    final installed = _storage.installedFile(descriptor, file);
    try {
      if (await installed.exists()) await installed.delete();
      return !await installed.exists();
    } on FileSystemException {
      // A file we cannot delete is the one case where unverified bytes survive;
      // the caller must be able to see that.
      return false;
    }
  }

  static Future<bool> _deleteStaging(Directory staging) async {
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Streams [file] through SHA-256, reporting cumulative bytes read.
  ///
  /// `openRead` yields chunks, so peak memory is one chunk regardless of a
  /// multi-gigabyte artifact.
  static Future<String> _hashFile(
    File file, {
    void Function(int processedBytes)? onBytes,
  }) async {
    final collector = _DigestCollector();
    final hasher = sha256.startChunkedConversion(collector);
    var processed = 0;
    await for (final chunk in file.openRead()) {
      hasher.add(chunk);
      processed += chunk.length;
      onBytes?.call(processed);
    }
    hasher.close();
    return collector.digest.toString();
  }
}

/// Captures the single [Digest] a chunked SHA-256 conversion emits on close.
class _DigestCollector implements Sink<Digest> {
  Digest? _digest;

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}

  Digest get digest {
    final value = _digest;
    if (value == null) {
      throw StateError('digest read before the hasher was closed');
    }
    return value;
  }
}
