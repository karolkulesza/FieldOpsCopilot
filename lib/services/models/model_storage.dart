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
///
/// **Not a security control.** The receipt sits in the same app-writable directory
/// as the weights, and its only link to the build is that its digest and size
/// agree with the descriptor — so anything able to replace the artifact could make
/// a receipt agree with it. Inside the iOS/Android sandbox that is fine, and it is
/// why [ModelInstallStatus.ready] means "verified earlier, cheaply re-confirmed"
/// rather than "these bytes are proven right now". The latter is what
/// `ModelProvisioner.verifyInstalled` is for.
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
  /// [nonce] scopes the staging path to a single transfer. Two transfers sharing
  /// one staging path is not merely wasteful, it is corrupting: POSIX `rename`
  /// preserves the inode, so once the first transfer renames the staging file
  /// into place, the second transfer's still-open sink keeps writing **into the
  /// installed artifact** — bytes nothing hashed. A per-transfer name makes that
  /// impossible regardless of how callers overlap.
  File stagingFile(ModelDescriptor descriptor, {String? nonce}) => File(
    p.join(
      root.path,
      nonce == null
          ? '${descriptor.fileName}$stagingSuffix'
          : '${descriptor.fileName}$stagingSuffix.$nonce',
    ),
  );

  /// Suffix marking a file as an in-progress or abandoned transfer.
  static const String stagingSuffix = '.part';

  /// Deletes every staging file for [descriptor], whatever its nonce.
  ///
  /// A process killed mid-transfer leaves its `.part.<nonce>` behind with nothing
  /// to resume it, so those bytes are swept rather than accumulated — a
  /// half-downloaded 2.4GB artifact is real disk pressure on a rugged device.
  /// [keep] spares the caller's own in-flight file.
  Future<void> deleteStagingFiles(
    ModelDescriptor descriptor, {
    File? keep,
  }) async {
    if (!await root.exists()) return;
    final prefix = '${descriptor.fileName}$stagingSuffix';
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! File) continue;
      if (!p.basename(entry.path).startsWith(prefix)) continue;
      if (keep != null && p.equals(entry.path, keep.path)) continue;
      try {
        await entry.delete();
      } on FileSystemException {
        // Another process may own it and be mid-transfer; leaving it is safe —
        // nothing installs from a staging path.
        continue;
      }
    }
  }

  /// Sidecar holding the [ModelInstallReceipt] for an installed artifact.
  File receiptFile(ModelDescriptor descriptor) =>
      File(p.join(root.path, '${descriptor.fileName}.receipt.json'));

  /// Deletes the receipt for [descriptor], if there is one.
  ///
  /// Called whenever a verification fails, because a receipt can outlive its
  /// artifact: if the multi-gigabyte file is later removed by hand to free space,
  /// a stale receipt would bless the next same-sized file to appear at that path —
  /// including a side-load nobody hashed.
  Future<void> deleteReceipt(ModelDescriptor descriptor) async {
    final file = receiptFile(descriptor);
    if (await file.exists()) await file.delete();
  }

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
  /// Returns `true` when exclusion is in force *as far as this platform can
  /// report*. Read that precisely, because the two platforms differ in kind:
  ///
  /// * iOS/macOS — **observed.** A native call either set the attribute or
  ///   failed, and the result says which.
  /// * Android — **declared.** The exclusion lives in the manifest and is applied
  ///   by the OS at backup time; there is nothing to call and nothing to observe
  ///   at runtime, so `true` here means "the app declares it", not "the OS was
  ///   seen honouring it". Evidence for that leg is the merged manifest at build
  ///   time, not this return value.
  Future<bool> exclude(Directory directory);
}

/// Exclusion that does nothing — the default for host unit tests, and honest
/// about it: it reports `false`, never a marking it did not apply.
class NoopBackupExclusion implements BackupExclusion {
  const NoopBackupExclusion();

  @override
  Future<bool> exclude(Directory directory) async => false;
}

/// How the running platform keeps a directory out of backups.
enum BackupExclusionMechanism {
  /// Declared in the app manifest, before the app ever runs (Android). There is
  /// nothing to call at runtime.
  manifest,

  /// A per-URL resource attribute that only native code can set
  /// (`NSURLIsExcludedFromBackupKey` on iOS/macOS), reached over a method
  /// channel.
  resourceAttribute,

  /// No mechanism — a host test runner, or a platform this app does not ship on.
  none,
}

/// Real per-platform no-backup marking.
///
/// The platforms do this in completely different places, which is why the
/// mechanism is named rather than hidden:
///
/// * **Android** — `android:fullBackupContent` and `android:dataExtractionRules`
///   in `AndroidManifest.xml` point at XML rules excluding `files/models` from
///   both cloud auto-backup and device-to-device transfer. Static, so it reports
///   [BackupExclusionMechanism.manifest] without a channel hop.
/// * **iOS/macOS** — `NSURLIsExcludedFromBackupKey` on the directory URL, set in
///   `ios/Runner/AppDelegate.swift` and invoked over [channel].
class PlatformBackupExclusion implements BackupExclusion {
  /// [mechanism] exists so tests can exercise a platform's path on any host: the
  /// unit suite runs on macOS locally and Linux in CI, and a check that silently
  /// takes a different branch per runner is not a check.
  const PlatformBackupExclusion({this._mechanism});

  final BackupExclusionMechanism? _mechanism;

  /// Channel implemented in `ios/Runner/AppDelegate.swift`. The method name and
  /// argument key here are a contract with that file.
  static const MethodChannel channel = MethodChannel(
    'field_ops_copilot/model_storage',
  );

  /// The mechanism in force, defaulting to the one the host platform provides.
  BackupExclusionMechanism get mechanism => _mechanism ?? mechanismFor();

  /// The mechanism the current platform provides.
  static BackupExclusionMechanism mechanismFor() {
    if (Platform.isAndroid) return BackupExclusionMechanism.manifest;
    if (Platform.isIOS || Platform.isMacOS) {
      return BackupExclusionMechanism.resourceAttribute;
    }
    return BackupExclusionMechanism.none;
  }

  @override
  Future<bool> exclude(Directory directory) async {
    switch (mechanism) {
      // Declared, not observed — see [BackupExclusion.exclude]. Nothing to call:
      // the manifest rules are what exclude the directory, and the OS applies
      // them at backup time.
      case BackupExclusionMechanism.manifest:
        return true;
      case BackupExclusionMechanism.none:
        return false;
      case BackupExclusionMechanism.resourceAttribute:
        try {
          final excluded = await channel.invokeMethod<bool>(
            'excludeFromBackup',
            {'path': directory.path},
          );
          return excluded ?? false;
        } on MissingPluginException {
          // No native handler (a host test, or a platform target that was never
          // built): report the truth. Never fail provisioning over a backup flag
          // — a model that downloaded fine is still usable.
          return false;
        } on PlatformException catch (error) {
          debugPrint('model backup exclusion failed: ${error.message}');
          return false;
        }
    }
  }
}
