import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Backs `PlatformBackupExclusion` in `lib/services/models/model_storage.dart`.
  /// The channel name, method name and argument key are a contract with that file.
  private static let modelStorageChannelName = "field_ops_copilot/model_storage"

  /// Retained for the lifetime of the app: a channel whose handler is set but
  /// which nothing holds stops answering once it is deallocated.
  private var modelStorageChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerModelStorageChannel(with: engineBridge.applicationRegistrar.messenger())
  }

  /// Exposes the one thing Dart cannot do for itself: marking a directory as
  /// excluded from iCloud and iTunes backup.
  ///
  /// Provisioned model weights are multi-gigabyte and re-downloadable from their
  /// source URL, so letting them into a backup burns the user's iCloud quota for
  /// no recovery value — and on a managed enterprise fleet, multiplies that waste
  /// by the device count. `NSURLIsExcludedFromBackupKey` is a per-URL resource
  /// attribute with no Flutter-side API, hence this channel.
  private func registerModelStorageChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.modelStorageChannelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String,
        !path.isEmpty
      else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "excludeFromBackup requires a non-empty 'path' argument",
            details: nil
          )
        )
        return
      }

      var url = URL(fileURLWithPath: path, isDirectory: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        result(true)
      } catch {
        // Reported to Dart as an error rather than thrown further: the weights
        // are still usable, so a failure here degrades the backup guarantee, it
        // does not fail provisioning.
        result(
          FlutterError(
            code: "exclude_failed",
            message: error.localizedDescription,
            details: path
          )
        )
      }
    }
    modelStorageChannel = channel
  }
}
