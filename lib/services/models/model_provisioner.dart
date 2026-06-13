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
class ModelProvisionProgress {
  const ModelProvisionProgress({
    required this.phase,
    required this.processedBytes,
    this.totalBytes,
  });

  final ModelProvisionPhase phase;
  final int processedBytes;

  /// Expected total, or `null` when it is genuinely unknown (a server that
  /// declared no `Content-Length` and a descriptor with no documented size).
  final int? totalBytes;

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
      'ModelProvisionProgress(${phase.name}, $processedBytes/$totalBytes)';
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
  /// A receipt from an earlier verification vouched for the file.
  receipt,

  /// A file that was already on disk was hashed now (side-loaded weights, or an
  /// install whose receipt was missing).
  existingFile,

  /// The bytes were downloaded and hashed during this run.
  download,
}

/// The artifact is installed and its bytes hash to the pinned digest.
final class ModelVerified extends ModelProvisionResult {
  const ModelVerified({
    required this.file,
    required this.sha256Hex,
    required this.sizeBytes,
    required this.source,
    required this.excludedFromBackup,
  });

  final File file;
  final String sha256Hex;
  final int sizeBytes;
  final ModelVerificationSource source;

  /// Whether the storage directory is genuinely marked no-backup. Reported
  /// rather than assumed, so the app never claims a platform guarantee it did not
  /// obtain.
  final bool excludedFromBackup;
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
/// [origin] matters to whoever reads this: bytes *fetched* and failing the pin
/// means the URL and hash disagree, while an *installed file* failing it usually
/// means the pin moved and the old artifact is still there.
final class ModelCorrupt extends ModelProvisionResult {
  const ModelCorrupt({
    required this.expectedSha256Hex,
    required this.actualSha256Hex,
    required this.sizeBytes,
    required this.origin,
    required this.quarantined,
  });

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

/// The artifact could not be fetched at all — transport error or an HTTP status
/// that is not `200`.
final class ModelDownloadFailed extends ModelProvisionResult {
  const ModelDownloadFailed({required this.message, this.statusCode});

  final String message;
  final int? statusCode;
}

/// Provisioning was refused because the build carries no usable source or no
/// pinned hash. Never a network or disk failure — always a configuration one.
final class ModelNotConfigured extends ModelProvisionResult {
  const ModelNotConfigured({required this.issue, required this.descriptor});

  final ModelConfigurationIssue issue;
  final ModelDescriptor descriptor;
}

/// Nothing is installed. Only returned by
/// [ModelProvisioner.verifyInstalled], which checks what is there rather than
/// fetching what is not.
final class ModelAbsent extends ModelProvisionResult {
  const ModelAbsent();
}

/// Downloads, verifies and installs on-device model weights.
///
/// The order of operations is the whole point of this class:
///
/// 1. bytes stream to a per-transfer `.part.<nonce>` staging file, never to the
///    final path;
/// 2. the SHA-256 is computed **during** that stream, so a 2.4GB artifact is
///    neither buffered in memory nor read twice;
/// 3. only a digest matching the pinned hash earns the atomic rename into place;
/// 4. fetched bytes that fail are deleted, and operations on one model are
///    serialised so two callers cannot interleave into each other's files.
///
/// That sequence is what makes "the model is ready" a claim about verified bytes
/// rather than about a file that happens to exist. It is also the client half of
/// the OTA-model-delivery design in the README: the server half (bucket layout,
/// device-capability-based selection, staged rollout) is narrated, not built.
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

  /// The current install state of [descriptor], answered from the receipt
  /// without hashing — cheap enough for a startup path and for the UI's
  /// "model ready" indicator.
  Future<ModelInstallStatus> statusOf(ModelDescriptor descriptor) =>
      _storage.statusOf(descriptor);

  /// Ensures verified weights for [descriptor] are installed, downloading them
  /// when what is on disk does not satisfy the pinned hash.
  ///
  /// Idempotent: with a valid receipt in place it does no I/O beyond the status
  /// check, so calling it on every launch is fine. Side-loaded weights (copied
  /// onto the device by hand for a demo) are hashed in place instead of being
  /// re-downloaded — and only if that hash *fails* is a download started, which is
  /// also the ordinary model-upgrade path when the pin moves to a new revision.
  ///
  /// Calls for the same model are **serialised** (see [_serialized]); overlapping
  /// callers do not race, and the second one usually finds the first one's result
  /// already installed.
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
        final installed = _storage.installedFile(descriptor);
        return ModelVerified(
          file: installed,
          sha256Hex: descriptor.sha256Hex,
          sizeBytes: await installed.length(),
          source: ModelVerificationSource.receipt,
          excludedFromBackup: excludedFromBackup,
        );

      case ModelInstallStatus.unverified:
        // Hash what is already there first — a side-loaded artifact must not
        // trigger a 2.4GB download just because it arrived without a receipt.
        final local = await _verifyExisting(
          descriptor,
          excludedFromBackup: excludedFromBackup,
          // Deliberately *not* quarantined yet: the usual reason a local file
          // fails the current pin is that the pin moved to a new revision, and
          // deleting the working old weights before the replacement exists would
          // strip an offline device of the only model it has. The download below
          // replaces it by atomic rename if and only if the new bytes verify.
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
  /// staging names (see [ModelStorage.stagingFile]) make that impossible; this
  /// queue additionally stops the redundant work, so the second caller simply sees
  /// the first one's verified install.
  ///
  /// Scope, stated honestly: this serialises callers of *this instance*, and an
  /// instance cannot span isolates or processes. The app has exactly one, from
  /// `modelProvisionerProvider`. Any two provisioners that do **not** share this
  /// queue — a second isolate as much as a second process — still interleave. That
  /// is no longer a *corrupting* interleave, because [stagingNonce] makes their
  /// staging paths disjoint and each transfer hashes and renames its own complete
  /// file; what remains is that the surviving receipt could describe the other
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

  /// Re-hashes the installed artifact, ignoring any receipt.
  ///
  /// This is the explicit integrity check — the receipt is a cache, and a cache
  /// cannot detect bytes that rotted after it was written (a truncated copy, a
  /// failing flash cell). Returns [ModelAbsent] when nothing is installed, and
  /// quarantines the file on mismatch exactly as a fresh download would.
  Future<ModelProvisionResult> verifyInstalled(
    ModelDescriptor descriptor, {
    ModelProvisionProgressCallback? onProgress,
  }) {
    // A source URL is irrelevant here — nothing is fetched — but a pinned hash
    // is the entire operation.
    if (!descriptor.hasPinnedHash) {
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
      if (!await _storage.installedFile(descriptor).exists()) {
        return const ModelAbsent();
      }
      return _verifyExisting(
        descriptor,
        excludedFromBackup: await _storage.prepare(),
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

  /// Hashes an artifact that is already on disk and files a receipt for it, or
  /// reports [ModelCorrupt] when the digest does not match.
  ///
  /// [quarantineOnMismatch] decides whether the offending file is deleted. The
  /// receipt is dropped either way: whatever it once vouched for, it does not
  /// vouch for a file that just failed the pin.
  Future<ModelProvisionResult> _verifyExisting(
    ModelDescriptor descriptor, {
    required bool excludedFromBackup,
    required bool quarantineOnMismatch,
    ModelProvisionProgressCallback? onProgress,
  }) async {
    final file = _storage.installedFile(descriptor);
    final totalBytes = await file.length();

    final digest = await _hashFile(
      file,
      onBytes: (processed) => onProgress?.call(
        ModelProvisionProgress(
          phase: ModelProvisionPhase.verifying,
          processedBytes: processed,
          totalBytes: totalBytes,
        ),
      ),
    );

    if (digest != descriptor.sha256Hex) {
      // Whatever the receipt once described, it does not describe a file that
      // just failed the pin.
      await _dropReceipt(descriptor);
      return ModelCorrupt(
        expectedSha256Hex: descriptor.sha256Hex,
        actualSha256Hex: digest,
        sizeBytes: totalBytes,
        origin: ModelByteOrigin.installedFile,
        quarantined: quarantineOnMismatch && await _quarantine(descriptor),
      );
    }

    await _storage.writeReceipt(
      descriptor,
      sha256Hex: digest,
      sizeBytes: totalBytes,
    );
    return ModelVerified(
      file: file,
      sha256Hex: digest,
      sizeBytes: totalBytes,
      source: ModelVerificationSource.existingFile,
      excludedFromBackup: excludedFromBackup,
    );
  }

  /// Streams the artifact to staging while hashing it, then installs it only if
  /// the digest matches.
  Future<ModelProvisionResult> _downloadAndInstall(
    ModelDescriptor descriptor, {
    required bool excludedFromBackup,
    ModelProvisionProgressCallback? onProgress,
  }) async {
    // A staging path unique to this transfer, so no two transfers can ever share
    // a sink or delete each other's bytes — see [ModelStorage.stagingFile].
    final staging = _storage.stagingFile(descriptor, nonce: stagingNonce());
    // Leftovers from an interrupted run carry no resumable state, so they are
    // swept rather than accumulated (a half-written 2.4GB file is real disk
    // pressure). Ours is spared by name. Note this unlinks a staging file another
    // writer may still be filling — POSIX allows that — which kills their transfer
    // at rename time rather than sparing it; see
    // [ModelStorage.deleteStagingFiles]. Harmless but not polite, and it cannot
    // happen between two callers of this instance, which the queue serialises.
    await _storage.deleteStagingFiles(descriptor, keep: staging);

    final ModelByteStream source;
    try {
      source = await _downloader.open(
        descriptor.downloadUri!,
        authToken: _authToken,
      );
    } on ModelDownloadException catch (error) {
      return ModelDownloadFailed(
        message: error.message,
        statusCode: error.statusCode,
      );
    } on SocketException catch (error) {
      return ModelDownloadFailed(message: 'network error: ${error.message}');
    } on HttpException catch (error) {
      return ModelDownloadFailed(message: 'http error: ${error.message}');
    }

    final declaredTotal = source.contentLength;
    final progressTotal = declaredTotal ?? descriptor.approximateSizeBytes;

    final collector = _DigestCollector();
    final hasher = sha256.startChunkedConversion(collector);
    var received = 0;

    try {
      final sink = staging.openWrite();
      try {
        await for (final chunk in source.bytes) {
          sink.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          onProgress?.call(
            ModelProvisionProgress(
              phase: ModelProvisionPhase.downloading,
              processedBytes: received,
              totalBytes: progressTotal,
            ),
          );
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } on Exception catch (error) {
      await _deleteIfExists(staging);
      return ModelDownloadFailed(message: 'transfer failed: $error');
    }

    // A body that does not match the length the server declared is a transfer
    // fault, not corruption — naming it correctly keeps the operator from
    // re-checking a hash that was never the problem. Short and long are named
    // separately because they have different causes (a dropped connection versus
    // a mis-declared or transport-encoded body).
    if (declaredTotal != null && received != declaredTotal) {
      await _deleteIfExists(staging);
      return ModelDownloadFailed(
        message: received < declaredTotal
            ? 'truncated transfer: received $received of $declaredTotal bytes'
            : 'over-long transfer: received $received bytes, '
                  'server declared $declaredTotal',
      );
    }

    hasher.close();
    final digest = collector.digest.toString();

    if (digest != descriptor.sha256Hex) {
      // The staging file is the only thing to remove — an artifact already
      // installed at the target path is deliberately left alone, so a device that
      // cannot fetch a valid replacement is not stripped of the weights it has.
      // The receipt still goes: it cannot vouch for anything now.
      final removed = await _deleteIfExists(staging);
      await _dropReceipt(descriptor);
      return ModelCorrupt(
        expectedSha256Hex: descriptor.sha256Hex,
        actualSha256Hex: digest,
        sizeBytes: received,
        origin: ModelByteOrigin.download,
        quarantined: removed,
      );
    }

    final installed = _storage.installedFile(descriptor);
    try {
      // Atomic swap. Replaces a stale artifact (a pin that moved) only now that
      // the replacement has been proven byte-for-byte.
      await staging.rename(installed.path);
    } on FileSystemException catch (error) {
      // Disk full, a permissions change, or another process having swept our
      // staging file. Reported through the sealed result type rather than thrown:
      // `provision` promises a `ModelProvisionResult`, and a caller forced to also
      // catch `FileSystemException` is a caller that will forget to.
      await _deleteIfExists(staging);
      return ModelDownloadFailed(
        message:
            'install failed: could not move the verified file into place '
            '(${error.osError?.message ?? error.message})',
      );
    }
    await _storage.writeReceipt(
      descriptor,
      sha256Hex: digest,
      sizeBytes: received,
    );

    return ModelVerified(
      file: installed,
      sha256Hex: digest,
      sizeBytes: received,
      source: ModelVerificationSource.download,
      excludedFromBackup: excludedFromBackup,
    );
  }

  /// Removes the receipt **unless it still vouches for what is on disk**.
  ///
  /// The unconditional version of this was too broad: a failed transfer would
  /// invalidate the receipt of an artifact it never touched — say a bad mirror
  /// serving junk while a good copy is already installed — forcing a needless
  /// re-hash of 2.4GB on the next launch. So the check is "does a valid receipt
  /// describe the installed file right now?", which keeps the guarantee that
  /// mattered (a receipt must never outlive the bytes it describes, or it would
  /// bless the next same-sized file to appear at that path) without punishing an
  /// install that is genuinely fine.
  ///
  /// Failing to delete is not worth failing provisioning over, but it does leave a
  /// stale receipt behind, so it is logged rather than swallowed.
  Future<bool> _dropReceipt(ModelDescriptor descriptor) async {
    try {
      if (await _storage.statusOf(descriptor) == ModelInstallStatus.ready) {
        return false;
      }
      await _storage.deleteReceipt(descriptor);
      return true;
    } on FileSystemException catch (error) {
      debugPrint('could not remove stale model receipt: ${error.message}');
      return false;
    }
  }

  /// Deletes every artifact of [descriptor], reporting whether the removal
  /// actually happened.
  Future<bool> _quarantine(ModelDescriptor descriptor) async {
    try {
      await _storage.deleteArtifact(descriptor);
      return !await _storage.installedFile(descriptor).exists();
    } on FileSystemException {
      // A file we cannot delete is the one case where unverified bytes survive;
      // the caller must be able to see that.
      return false;
    }
  }

  static Future<bool> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
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
