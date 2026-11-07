import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CasRandPhotoLibrary")
    else { return }
    let channel = FlutterMethodChannel(
      name: "io.github.khkjdfkjhdsfakhds.casrandforge/photo_library",
      binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "saveImage",
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String,
        let name = arguments["name"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        guard status == .authorized || status == .limited else {
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "permission_denied",
                message: "Photo library permission was denied.",
                details: nil))
          }
          return
        }
        // A resource request stores the file as is; UIImage-based saving would
        // re-encode it and lose the NovelAI metadata.
        PHPhotoLibrary.shared().performChanges({
          let options = PHAssetResourceCreationOptions()
          options.originalFilename = name
          PHAssetCreationRequest.forAsset().addResource(
            with: .photo, fileURL: URL(fileURLWithPath: path), options: options)
        }) { success, error in
          DispatchQueue.main.async {
            if success {
              result(nil)
            } else {
              result(
                FlutterError(
                  code: "save_failed",
                  message: error?.localizedDescription ?? "Photos rejected the image.",
                  details: nil))
            }
          }
        }
      }
    }
  }
}
