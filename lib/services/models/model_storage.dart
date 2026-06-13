import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model_descriptor.dart';

/// What the on-disk state of a model artifact is, from the app's point of view.
enum ModelInstallStatus {
  /// No artifact file present — provisioning must download it.
  absent,

  /// A file is present but its integrity has not been established against the
  /// currently pinned hash: no receipt, a receipt from a different pin, or a
  /// size that no longer matches. Reached both by an interrupted install and by
  /// the demo-day flow where the weights are side-loaded onto the device by
  /// hand.
  unverified,

  /// A file is present and a receipt vouches for it against the pinned hash.
  ready,
}

/// Proof that a specific artifact was verified against a specific pinned hash.
///
/// Re-hashing 2.4GB on every launch to answer "is the model ready?" would cost
/// seconds of I/O and battery on the exact devices this app targets. The receipt
/// is written once, immediately after a successful verification, and read on
/// startup instead. It is a *cache of a verification*, not a substitute for one:
/// `ModelProvisioner.verifyInstalled` still re-hashes on demand, and the receipt
/// is invalidated automatically whenever the pinned hash or the file size moves.
@immutable
class ModelInstallReceipt {
  const ModelInstallReceipt({
    required this.modelId,
    required this.sha256Hex,
    required this.sizeBytes,
  });

  final String modelId;
  final String sha256Hex;
  final int sizeBytes;

  Map<String, Object?> toJson() => {
    'modelId': modelId,
    'sha256': sha256Hex,
    'sizeBytes': sizeBytes,
  };

  /// Parses a receipt, returning `null` for anything malformed.
  ///
  /// A corrupt receipt must degrade to [ModelInstallStatus.unverified] (which
  /// triggers a re-hash) rather than throwing on the startup path.
  static ModelInstallReceipt? tryParse(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      final id = json['modelId'];
      final hash = json['sha256'];
      final size = json['sizeBytes'];
      if (id is! String || hash is! String || size is! int) return null;
      return ModelInstallReceipt(modelId: id, sha256Hex: hash, sizeBytes: size);
    } on FormatException {
      return null;
    }
  }
}

/// Filesystem layout and lifecycle for provisioned model weights.
///
/// Weights live in the **application-support directory** (not the cache
/// directory): iOS may evict `Library/Caches` under storage pressure, and a
/// technician in a basement with no connectivity cannot re-download 2.4GB. The
/// directory is marked *excluded from backup* instead, so multi-gigabyte weights
/// never pollute an iCloud or Android auto-backup — they are reproducible from
/// the source URL, which is exactly what a backup should not carry.
class ModelStorage {
  ModelStorage({
    required this.root,
    this._backupExclusion = const NoopBackupExclusion(),
  });

  /// Opens the app's real model directory: `<application support>/models`.
  static Future<ModelStorage> openDefault() async {
    final support = await getApplicationSupportDirectory();
    return ModelStorage(
      root: Directory(p.join(support.path, 'models')),
      backupExclusion: const PlatformBackupExclusion(),
    );
  }

  /// Directory holding every provisioned artifact.
  final Directory root;

  final BackupExclusion _backupExclusion;

  /// Where a fully verified artifact lives. Only ever created by an atomic
  /// rename from [stagingFile], so a path that exists is never a partial body.
  File installedFile(ModelDescriptor descriptor) =>
      File(p.join(root.path, descriptor.fileName));

  /// Where bytes land while downloading.
  ///
  /// Downloading straight to [installedFile] would leave a partial body sitting
  /// at the path the engine loads from, so an engine starting up mid-download —
  /// or after a crashed one — could memory-map a half-written file and fail in a
  /// way that looks like a model bug. Staging plus rename-after-verify makes the
  /// install atomic: the final path only ever appears complete and verified.
  ///
  /// Note what this does *not* claim. Bytes that fail verification are deleted
  /// immediately, including an already-installed artifact whose pinned hash has
  /// moved; unverified weights must not stay loadable, so there is deliberately
  /// no "keep the old copy until the new one arrives" behaviour to fall back on.
  File stagingFile(ModelDescriptor descriptor) =>
      File(p.join(root.path, '${descriptor.fileName}.part'));

  /// Sidecar holding the [ModelInstallReceipt] for an installed artifact.
  File receiptFile(ModelDescriptor descriptor) =>
      File(p.join(root.path, '${descriptor.fileName}.receipt.json'));

  /// Creates the directory and applies the platform's no-backup marking.
  ///
  /// Returns whether exclusion from backup is actually in force, so a caller can
  /// report the truth instead of assuming it: the marking is a platform call that
  /// can legitimately be unavailable (a host unit test, an unimplemented channel).
  Future<bool> prepare() async {
    await root.create(recursive: true);
    return _backupExclusion.exclude(root);
  }

  /// The current on-disk state of [descriptor], answered without hashing.
  Future<ModelInstallStatus> statusOf(ModelDescriptor descriptor) async {
    final file = installedFile(descriptor);
    if (!await file.exists()) return ModelInstallStatus.absent;

    // Without a pinned hash there is nothing a receipt could vouch against, so
    // the file cannot be called ready however it got there.
    if (!descriptor.hasPinnedHash) return ModelInstallStatus.unverified;

    final receipt = await readReceipt(descriptor);
    if (receipt == null) return ModelInstallStatus.unverified;
    if (receipt.modelId != descriptor.id) return ModelInstallStatus.unverified;
    if (receipt.sha256Hex != descriptor.sha256Hex) {
      return ModelInstallStatus.unverified;
    }
    // A size change proves the bytes moved since the receipt was written, so the
    // receipt no longer describes this file.
    if (receipt.sizeBytes != await file.length()) {
      return ModelInstallStatus.unverified;
    }
    return ModelInstallStatus.ready;
  }

  /// Reads the receipt for [descriptor], or `null` when absent or malformed.
  Future<ModelInstallReceipt?> readReceipt(ModelDescriptor descriptor) async {
    final file = receiptFile(descriptor);
    if (!await file.exists()) return null;
    return ModelInstallReceipt.tryParse(await file.readAsString());
  }

  /// Records a successful verification of [descriptor].
  Future<void> writeReceipt(
    ModelDescriptor descriptor, {
    required String sha256Hex,
    required int sizeBytes,
  }) async {
    final receipt = ModelInstallReceipt(
      modelId: descriptor.id,
      sha256Hex: sha256Hex,
      sizeBytes: sizeBytes,
    );
    await receiptFile(descriptor).writeAsString(jsonEncode(receipt.toJson()));
  }

  /// Removes every trace of [descriptor]: artifact, staging file and receipt.
  ///
  /// Used to quarantine bytes that failed verification. Leaving a stale receipt
  /// behind would be worse than leaving nothing, because a later download of the
  /// same size would inherit a receipt it never earned.
  Future<void> deleteArtifact(ModelDescriptor descriptor) async {
    for (final file in [
      installedFile(descriptor),
      stagingFile(descriptor),
      receiptFile(descriptor),
    ]) {
      if (await file.exists()) await file.delete();
    }
  }
}

/// Marks a directory as excluded from OS and cloud backup.
abstract interface class BackupExclusion {
  /// Applies the platform's no-backup marking to [directory].
  ///
  /// Returns `true` only when exclusion is genuinely in force.
  Future<bool> exclude(Directory directory);
}

/// Exclusion that does nothing — the default for host unit tests, and honest
/// about it: it reports `false`, never a marking it did not apply.
class NoopBackupExclusion implements BackupExclusion {
  const NoopBackupExclusion();

  @override
  Future<bool> exclude(Directory directory) async => false;
}

/// Real per-platform no-backup marking.
///
/// The two platforms do this in completely different places:
///
/// * **iOS/macOS** — a per-URL resource attribute (`NSURLIsExcludedFromBackupKey`)
///   that only native code can set, so it goes over a method channel handled in
///   `AppDelegate.swift`.
/// * **Android** — declarative, in the manifest: `android:fullBackupContent` and
///   `android:dataExtractionRules` point at XML rules that exclude `files/models`
///   from both auto-backup and device-to-device transfer. There is nothing to
///   call at runtime, which is why this reports `true` without a channel hop.
class PlatformBackupExclusion implements BackupExclusion {
  const PlatformBackupExclusion();

  /// Channel implemented in `ios/Runner/AppDelegate.swift`.
  static const MethodChannel channel = MethodChannel(
    'field_ops_copilot/model_storage',
  );

  @override
  Future<bool> exclude(Directory directory) async {
    // Handled declaratively by the manifest backup rules; see class docs.
    if (Platform.isAndroid) return true;
    if (!Platform.isIOS && !Platform.isMacOS) return false;
    try {
      final excluded = await channel.invokeMethod<bool>('excludeFromBackup', {
        'path': directory.path,
      });
      return excluded ?? false;
    } on MissingPluginException {
      // No native handler (e.g. a host test): report the truth, do not fail
      // provisioning over a backup flag.
      return false;
    } on PlatformException catch (error) {
      debugPrint('model backup exclusion failed: ${error.message}');
      return false;
    }
  }
}
