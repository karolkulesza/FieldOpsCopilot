import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model_descriptor.dart';

/// What the on-disk state of a model artifact is, from the app's point of view.
enum ModelInstallStatus {
  /// At least one required file is missing — provisioning must download the set.
  absent,

  /// Every file is present but the set's integrity has not been established
  /// against the currently pinned hashes: a missing receipt, a receipt from a
  /// different pin, or a size that no longer matches, on any file. Reached both
  /// by an interrupted install and by the demo-day flow where the weights are
  /// side-loaded onto the device by hand.
  unverified,

  /// Every file is present and a receipt vouches for each one against its
  /// pinned hash.
  ready,
}

/// Proof that a specific file was verified against a specific pinned hash.
///
/// Re-hashing 2.6GB on every launch to answer "is the model ready?" would cost
/// seconds of I/O and battery on the exact devices this app targets. A receipt
/// is written once, immediately after a successful verification, and read on
/// startup instead. It is a *cache of a verification*, not a substitute for one:
/// `ModelProvisioner.verifyInstalled` still re-hashes on demand, and the receipt
/// is invalidated automatically whenever the pinned hash or the file size moves.
///
/// One receipt describes one **file** (Task 2.0: a model may be several). Which
/// file is identified by where the receipt sits — the sidecar next to it — so the
/// JSON shape is unchanged from Task 1.7 and every receipt already on a device
/// stays valid.
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
/// technician in a basement with no connectivity cannot re-download 2.6GB. The
/// directory is marked *excluded from backup* instead, so multi-gigabyte weights
/// never pollute an iCloud or Android auto-backup — they are reproducible from
/// the source URL, which is exactly what a backup should not carry.
///
/// **Layout (Task 2.0).** Each model owns a subdirectory named by its id:
///
/// ```text
/// <root>/<model id>/<file>                    installed artifact file
/// <root>/<model id>/<file>.receipt.json       its verification receipt
/// <root>/<model id>.part.<nonce>/             an in-flight staged download
/// ```
///
/// Task 1.7 installed a model's single file flat in `<root>`; the demo device
/// carries a 2.59GB Gemma install in that layout, and re-downloading it because
/// the path moved is exactly the regression `ModelArtifactFile.fileName`'s doc
/// warned about. So [statusOf] migrates the legacy layout by `rename` — same
/// volume, so it is a metadata operation regardless of file size — before
/// answering.
class ModelStorage {
  ModelStorage({
    required this.root,
    BackupExclusion backupExclusion = const NoopBackupExclusion(),
  }) : _backupExclusion = backupExclusion;

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

  /// The directory a model's verified files live in.
  Directory installDir(ModelDescriptor descriptor) =>
      Directory(p.join(root.path, descriptor.id));

  /// Where a fully verified file lives. Only ever created by an atomic rename
  /// from inside a staging directory, so a path that exists is never a partial
  /// body.
  ///
  /// [file] defaults to the descriptor's [ModelDescriptor.soleFile], which keeps
  /// every single-file call site (the LLM config, the integration tests) exact:
  /// on a multi-file model, omitting [file] throws rather than guessing.
  File installedFile(ModelDescriptor descriptor, [ModelArtifactFile? file]) =>
      File(p.join(installDir(descriptor).path, (file ?? descriptor.soleFile).fileName));

  /// Where a transfer's bytes land while downloading: a directory holding the
  /// whole set, renamed file-by-file into [installDir] only after *every* file
  /// has verified.
  ///
  /// Downloading straight to [installedFile] would leave a partial body sitting
  /// at the path the engine loads from, so an engine starting up mid-download —
  /// or after a crashed one — could memory-map a half-written file and fail in a
  /// way that looks like a model bug. Staging plus rename-after-verify makes the
  /// install atomic: the final path only ever appears complete and verified.
  ///
  /// [nonce] scopes the staging directory to a single transfer. Two transfers
  /// sharing one staging path is not merely wasteful, it is corrupting: POSIX
  /// `rename` preserves the inode, so once the first transfer renames a staged
  /// file into place, the second transfer's still-open sink keeps writing **into
  /// the installed artifact** — bytes nothing hashed. A per-transfer name makes
  /// that impossible regardless of how callers overlap.
  Directory stagingDir(ModelDescriptor descriptor, {String? nonce}) =>
      Directory(
        p.join(
          root.path,
          nonce == null
              ? '${descriptor.id}$stagingSuffix'
              : '${descriptor.id}$stagingSuffix.$nonce',
        ),
      );

  /// Suffix marking a directory as an in-progress or abandoned transfer.
  static const String stagingSuffix = '.part';

  /// Deletes every staging directory for [descriptor], whatever its nonce,
  /// except [keep].
  ///
  /// A process killed mid-transfer leaves its `.part.<nonce>` behind with nothing
  /// to resume it, so those bytes are swept rather than accumulated — a
  /// half-downloaded 2.6GB artifact is real disk pressure on a rugged device.
  ///
  /// Be clear about what this does to a *concurrent* writer, because it is not
  /// gentle: on POSIX the unlink **succeeds** even while another writer holds a
  /// file open. That writer keeps filling an unlinked inode and only discovers the
  /// problem when its rename finds nothing to move — which the provisioner catches
  /// and reports as a failed install. So the sweep reliably kills a competing
  /// transfer rather than sparing it. Nothing is corrupted (the killed transfer
  /// installs nothing), and within one provisioner the queue means it cannot
  /// happen; a second isolate or process is where it can, and it loses its
  /// download.
  Future<void> deleteStagingDirs(
    ModelDescriptor descriptor, {
    Directory? keep,
  }) async {
    if (!await root.exists()) return;
    final prefix = '${descriptor.id}$stagingSuffix';
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory) continue;
      if (!p.basename(entry.path).startsWith(prefix)) continue;
      if (keep != null && p.equals(entry.path, keep.path)) continue;
      try {
        await entry.delete(recursive: true);
      } on FileSystemException {
        // Reached where an open file cannot be unlinked (Windows), not on the
        // platforms this app ships to — POSIX unlinks it regardless, see the doc
        // comment. Either way a staging directory left behind is harmless:
        // nothing is ever installed from a staging path.
        continue;
      }
    }
  }

  /// Sidecar holding the [ModelInstallReceipt] for one installed file.
  File receiptFile(ModelDescriptor descriptor, [ModelArtifactFile? file]) =>
      File(
        '${installedFile(descriptor, file ?? descriptor.soleFile).path}'
        '.receipt.json',
      );

  /// Deletes the receipts of every file whose receipt no longer vouches for
  /// what is on disk.
  ///
  /// Called whenever a verification fails, because a receipt can outlive its
  /// file: if a multi-gigabyte file is later removed by hand to free space, a
  /// stale receipt would bless the next same-sized file to appear at that path —
  /// including a side-load nobody hashed. Per-file rather than per-model on
  /// purpose: a corrupt download of one file says nothing about the receipts of
  /// its already-verified set-mates, and dropping those would force a needless
  /// re-hash.
  Future<void> deleteStaleReceipts(ModelDescriptor descriptor) async {
    for (final file in descriptor.files) {
      if (await fileVerified(descriptor, file)) continue;
      final receipt = receiptFile(descriptor, file);
      if (await receipt.exists()) await receipt.delete();
    }
  }

  /// Creates the root directory and applies the platform's no-backup marking.
  ///
  /// Returns whether exclusion from backup is actually in force, so a caller can
  /// report the truth instead of assuming it: the marking is a platform call that
  /// can legitimately be unavailable (a host unit test, an unimplemented channel).
  ///
  /// The marking is applied to [root], which covers every model subdirectory
  /// beneath it — `NSURLIsExcludedFromBackupKey` and the Android manifest rules
  /// are both subtree-scoped.
  Future<bool> prepare() async {
    await root.create(recursive: true);
    return _backupExclusion.exclude(root);
  }

  /// The current on-disk state of [descriptor], answered without hashing.
  ///
  /// A set is [ModelInstallStatus.ready] only when **every** file is present and
  /// vouched for; one missing file makes it [ModelInstallStatus.absent] and one
  /// unvouched file makes it [ModelInstallStatus.unverified]. Missing wins over
  /// unvouched because the operator's next action differs: fetch versus verify.
  Future<ModelInstallStatus> statusOf(ModelDescriptor descriptor) async {
    await _migrateLegacyLayout(descriptor);

    for (final file in descriptor.files) {
      if (!await installedFile(descriptor, file).exists()) {
        return ModelInstallStatus.absent;
      }
    }
    for (final file in descriptor.files) {
      if (!await fileVerified(descriptor, file)) {
        return ModelInstallStatus.unverified;
      }
    }
    return ModelInstallStatus.ready;
  }

  /// Whether [file] is present and its receipt vouches for it against the
  /// currently pinned hash. Never hashes.
  Future<bool> fileVerified(
    ModelDescriptor descriptor,
    ModelArtifactFile file,
  ) async {
    final installed = installedFile(descriptor, file);
    if (!await installed.exists()) return false;

    // Without a pinned hash there is nothing a receipt could vouch against, so
    // the file cannot be called verified however it got there.
    if (!file.hasPinnedHash) return false;

    final receipt = await readReceipt(descriptor, file);
    if (receipt == null) return false;
    if (receipt.modelId != descriptor.id) return false;
    if (receipt.sha256Hex != file.sha256Hex) return false;
    // A size change proves the bytes moved since the receipt was written, so the
    // receipt no longer describes this file.
    if (receipt.sizeBytes != await installed.length()) return false;
    return true;
  }

  /// Reads the receipt for one file of [descriptor], or `null` when absent or
  /// malformed.
  Future<ModelInstallReceipt?> readReceipt(
    ModelDescriptor descriptor, [
    ModelArtifactFile? file,
  ]) async {
    final sidecar = receiptFile(descriptor, file ?? descriptor.soleFile);
    if (!await sidecar.exists()) return null;
    return ModelInstallReceipt.tryParse(await sidecar.readAsString());
  }

  /// Records a successful verification of one file of [descriptor].
  Future<void> writeReceipt(
    ModelDescriptor descriptor, {
    required ModelArtifactFile file,
    required String sha256Hex,
    required int sizeBytes,
  }) async {
    final receipt = ModelInstallReceipt(
      modelId: descriptor.id,
      sha256Hex: sha256Hex,
      sizeBytes: sizeBytes,
    );
    await receiptFile(
      descriptor,
      file,
    ).writeAsString(jsonEncode(receipt.toJson()));
  }

  /// Removes every trace of [descriptor]: its install directory (files and
  /// receipts), any staging directories, and any legacy flat-layout leftovers.
  ///
  /// Used to quarantine bytes that failed verification. Leaving a stale receipt
  /// behind would be worse than leaving nothing, because a later download of the
  /// same size would inherit a receipt it never earned.
  Future<void> deleteArtifact(ModelDescriptor descriptor) async {
    final dir = installDir(descriptor);
    if (await dir.exists()) await dir.delete(recursive: true);
    await deleteStagingDirs(descriptor);
    // Legacy flat layout: normally migrated into the install directory before
    // anything could want it deleted, but a quarantine must not depend on a
    // migration having run.
    for (final file in descriptor.files) {
      for (final legacy in [
        _legacyInstalledFile(file),
        _legacyReceiptFile(file),
      ]) {
        if (await legacy.exists()) await legacy.delete();
      }
    }
  }

  /// Task 1.7's flat layout: the artifact file directly in [root].
  File _legacyInstalledFile(ModelArtifactFile file) =>
      File(p.join(root.path, file.fileName));

  File _legacyReceiptFile(ModelArtifactFile file) =>
      File(p.join(root.path, '${file.fileName}.receipt.json'));

  /// Moves a Task 1.7 flat-layout install into the model's subdirectory.
  ///
  /// `rename` within one volume is a metadata operation, so migrating the demo
  /// device's 2.59GB Gemma install costs milliseconds and no disk — where
  /// re-downloading it would cost venue Wi-Fi a coin flip, which is the failure
  /// mode the readiness banner exists to prevent. The receipt moves with its
  /// file and its JSON shape is unchanged, so a migrated install stays `ready`
  /// without re-hashing.
  ///
  /// Each path moves only when the source exists and the target does not: an
  /// install already in the new layout is never overwritten by a stale flat one.
  Future<void> _migrateLegacyLayout(ModelDescriptor descriptor) async {
    for (final file in descriptor.files) {
      final legacyFile = _legacyInstalledFile(file);
      if (await legacyFile.exists()) {
        final target = installedFile(descriptor, file);
        if (!await target.exists()) {
          await installDir(descriptor).create(recursive: true);
          try {
            await legacyFile.rename(target.path);
          } on FileSystemException catch (error) {
            // A migration that cannot happen must not take the startup path
            // down with it — the status check then honestly reports `absent`.
            debugPrint('legacy model layout migration failed: ${error.message}');
            continue;
          }
        }
      }
      final legacyReceipt = _legacyReceiptFile(file);
      if (await legacyReceipt.exists()) {
        final target = receiptFile(descriptor, file);
        if (!await target.exists() &&
            await installedFile(descriptor, file).exists()) {
          await installDir(descriptor).create(recursive: true);
          try {
            await legacyReceipt.rename(target.path);
          } on FileSystemException catch (error) {
            debugPrint(
              'legacy model receipt migration failed: ${error.message}',
            );
          }
        }
      }
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
  const PlatformBackupExclusion({BackupExclusionMechanism? mechanism})
    : _mechanism = mechanism;

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
