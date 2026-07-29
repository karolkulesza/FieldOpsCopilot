import 'dart:io';

import 'package:crypto/crypto.dart';

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

/// Bytes were obtained but do not hash to the pinned digest.
///
/// The bytes are gone by the time this is returned: weights that failed
/// verification must never be left where an engine could memory-map them.
final class ModelCorrupt extends ModelProvisionResult {
  const ModelCorrupt({
    required this.expectedSha256Hex,
    required this.actualSha256Hex,
    required this.sizeBytes,
    required this.quarantined,
  });

  final String expectedSha256Hex;
  final String actualSha256Hex;
  final int sizeBytes;

  /// Whether the offending bytes were successfully removed.
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
/// 1. bytes stream to a `.part` staging file, never to the final path;
/// 2. the SHA-256 is computed **during** that stream, so a 2.4GB artifact is
///    neither buffered in memory nor read twice;
/// 3. only a digest matching the pinned hash earns the atomic rename into place;
/// 4. anything else is deleted, and a previously verified copy is left untouched.
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

  /// The current install state of [descriptor], answered from the receipt
  /// without hashing — cheap enough for a startup path and for the UI's
  /// "model ready" indicator.
  Future<ModelInstallStatus> statusOf(ModelDescriptor descriptor) =>
      _storage.statusOf(descriptor);

  /// Ensures verified weights for [descriptor] are installed, downloading them
  /// if necessary.
  ///
  /// Idempotent: with a valid receipt in place it does no I/O beyond the status
  /// check, so calling it on every launch is fine. Side-loaded weights (copied
  /// onto the device by hand for a demo) are hashed in place instead of being
  /// re-downloaded.
  Future<ModelProvisionResult> provision(
    ModelDescriptor descriptor, {
    ModelProvisionProgressCallback? onProgress,
  }) async {
    final issue = descriptor.configurationIssue;
    if (issue != null) {
      return ModelNotConfigured(issue: issue, descriptor: descriptor);
    }

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
        return _verifyExisting(
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

  /// Re-hashes the installed artifact, ignoring any receipt.
  ///
  /// This is the explicit integrity check — the receipt is a cache, and a cache
  /// cannot detect bytes that rotted after it was written (a truncated copy, a
  /// failing flash cell). Returns [ModelAbsent] when nothing is installed, and
  /// quarantines the file on mismatch exactly as a fresh download would.
  Future<ModelProvisionResult> verifyInstalled(
    ModelDescriptor descriptor, {
    ModelProvisionProgressCallback? onProgress,
  }) async {
    // A source URL is irrelevant here — nothing is fetched — but a pinned hash
    // is the entire operation.
    if (!descriptor.hasPinnedHash) {
      return ModelNotConfigured(
        issue: ModelConfigurationIssue.unpinnedHash,
        descriptor: descriptor,
      );
    }
    if (!await _storage.installedFile(descriptor).exists()) {
      return const ModelAbsent();
    }
    return _verifyExisting(
      descriptor,
      excludedFromBackup: await _storage.prepare(),
      onProgress: onProgress,
    );
  }

  /// Releases the downloader's transport resources.
  void dispose() => _downloader.close();

  /// Hashes an artifact that is already on disk and files a receipt for it, or
  /// removes it when the digest does not match.
  Future<ModelProvisionResult> _verifyExisting(
    ModelDescriptor descriptor, {
    required bool excludedFromBackup,
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
      return ModelCorrupt(
        expectedSha256Hex: descriptor.sha256Hex,
        actualSha256Hex: digest,
        sizeBytes: totalBytes,
        quarantined: await _quarantine(descriptor),
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
    final staging = _storage.stagingFile(descriptor);
    // A leftover `.part` is a previous run's partial body, and nothing resumes a
    // transfer today. `openWrite` truncates, so those bytes would not survive
    // anyway; deleting explicitly means the invariant does not rest on that
    // default — switching to append mode would otherwise splice two partial
    // bodies into a file that hashes to nothing and reads as corruption.
    if (await staging.exists()) await staging.delete();

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

    // A body shorter than the server declared is a truncated transfer, not
    // corruption — naming it correctly keeps the operator from re-checking a
    // hash that was never the problem.
    if (declaredTotal != null && received != declaredTotal) {
      await _deleteIfExists(staging);
      return ModelDownloadFailed(
        message:
            'truncated transfer: received $received of $declaredTotal bytes',
      );
    }

    hasher.close();
    final digest = collector.digest.toString();

    if (digest != descriptor.sha256Hex) {
      return ModelCorrupt(
        expectedSha256Hex: descriptor.sha256Hex,
        actualSha256Hex: digest,
        sizeBytes: received,
        // Only the staging file exists at this point; any previously installed
        // artifact is untouched and stays valid.
        quarantined: await _deleteIfExists(staging),
      );
    }

    final installed = _storage.installedFile(descriptor);
    await staging.rename(installed.path);
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
