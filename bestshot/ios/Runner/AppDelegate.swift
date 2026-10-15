import Flutter
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ImageIO

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  
  private enum PickerPurpose { case folder, openReview, saveReview }
  private var pickerPurpose = PickerPurpose.folder
  private var reviewExportDirectory: URL?
  private var directoryResult: FlutterResult?
  private var directoryScopes: [URL] = []
  private var faceDetector: CIDetector?
  // Analyzer isolates share this detector; serialize access to its native state.
  private let faceQueue = DispatchQueue(label: "com.takuenjoy.bestshot.faces", qos: .userInitiated)

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    
    // Initialize CoreImage face detector
    let options = [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    faceDetector = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: options)
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    
    // Register custom MethodChannel using the implicit engine's registry
    // Background isolates forward requests through the root engine messenger.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VisionPlugin")
    registerMethodChannel(with: registrar?.messenger())
  }
  
  private func registerMethodChannel(with binaryMessenger: FlutterBinaryMessenger?) {
    guard let messenger = binaryMessenger else { return }
    let channel = FlutterMethodChannel(name: "com.example.bestshot/vision", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { return }
      if call.method == "detectFaces" {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result([])
          return
        }
        self.detectFaces(in: path, result: result)
      } else if call.method == "decodeImage" {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "invalid_path", message: "画像パスがありません", details: nil))
          return
        }
        let maxEdge = min(4096, max(224, args["maxEdge"] as? Int ?? 1920))
        self.decodeImage(path: path, maxEdge: maxEdge, result: result)
      } else if call.method == "pickDirectory" {
        self.pickDirectory(result: result)
      } else if call.method == "openReviewSession" {
        self.presentPicker(UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false), purpose: .openReview, result: result)
      } else if call.method == "saveReviewSession" {
        guard let args = call.arguments as? [String: Any], let bytes = args["bytes"] as? FlutterStandardTypedData else {
          result(FlutterError(code: "invalid_data", message: "保存データがありません", details: nil))
          return
        }
        self.saveReviewSession(bytes.data, result: result)
      } else if call.method == "captureFolderBookmarks" {
        let paths = (call.arguments as? [String: Any])?["paths"] as? [String] ?? []
        var bookmarks: [String: String] = [:]
        for url in self.directoryScopes where paths.contains(where: { $0.hasPrefix(url.path + "/") }) {
          if let data = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks[url.path] = data.base64EncodedString()
          }
        }
        result(bookmarks)
      } else if call.method == "restoreFolderBookmarks" {
        var restoredPaths: [String: String] = [:]
        for (oldPath, encoded) in call.arguments as? [String: String] ?? [:] {
          guard let data = Data(base64Encoded: encoded) else { continue }
          var stale = false
          if let url = try? URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale),
             self.directoryScopes.contains(url) || url.startAccessingSecurityScopedResource() {
            if !self.directoryScopes.contains(url) { self.directoryScopes.append(url) }
            restoredPaths[oldPath] = url.path
          }
        }
        result(restoredPaths)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func decodeImage(path: String, maxEdge: Int, result: @escaping FlutterResult) {
    faceQueue.async {
      autoreleasepool {
        let options: [CFString: Any] = [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maxEdge,
          kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.95) else {
          DispatchQueue.main.async {
            result(FlutterError(code: "decode_failed", message: "画像を読み込めませんでした", details: nil))
          }
          return
        }
        DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data)) }
      }
    }
  }

  private func pickDirectory(result: @escaping FlutterResult) {
    presentPicker(UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false), purpose: .folder, result: result)
  }

  private func presentPicker(_ picker: UIDocumentPickerViewController, purpose: PickerPurpose, result: @escaping FlutterResult) {
    guard directoryResult == nil else {
      result(FlutterError(code: "busy", message: "ファイルを選択中です", details: nil))
      return
    }
    var presenter = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?.rootViewController
    while let presented = presenter?.presentedViewController { presenter = presented }
    guard let presenter = presenter else {
      cleanupReviewExport()
      result(FlutterError(code: "no_window", message: "画面を開けませんでした", details: nil))
      return
    }
    directoryResult = result
    pickerPurpose = purpose
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  private func saveReviewSession(_ data: Data, result: @escaping FlutterResult) {
    guard directoryResult == nil else {
      result(FlutterError(code: "busy", message: "ファイルを選択中です", details: nil))
      return
    }
    do {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bestshot-export-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      reviewExportDirectory = directory
      let url = directory.appendingPathComponent("selection.bestshot")
      try data.write(to: url, options: .atomic)
      presentPicker(UIDocumentPickerViewController(forExporting: [url], asCopy: true), purpose: .saveReview, result: result)
    } catch {
      cleanupReviewExport()
      result(FlutterError(code: "save_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func cleanupReviewExport() {
    if let directory = reviewExportDirectory { try? FileManager.default.removeItem(at: directory) }
    reviewExportDirectory = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let result = directoryResult
    directoryResult = nil
    guard let url = urls.first else { cleanupReviewExport(); result?(nil); return }
    switch pickerPurpose {
    case .folder:
      if !directoryScopes.contains(url) && url.startAccessingSecurityScopedResource() {
        directoryScopes.append(url)
      }
      result?(url.path)
    case .saveReview:
      cleanupReviewExport()
      result?(true)
    case .openReview:
      let accessed = url.startAccessingSecurityScopedResource()
      faceQueue.async {
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
          let data = try Data(contentsOf: url)
          DispatchQueue.main.async { result?(FlutterStandardTypedData(bytes: data)) }
        } catch {
          DispatchQueue.main.async { result?(FlutterError(code: "open_failed", message: error.localizedDescription, details: nil)) }
        }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    directoryResult?(nil)
    directoryResult = nil
    cleanupReviewExport()
  }

  deinit {
    for url in directoryScopes { url.stopAccessingSecurityScopedResource() }
  }

  private func detectFaces(in path: String, result: @escaping FlutterResult) {
    faceQueue.async {
      guard let detector = self.faceDetector,
            let image = UIImage(contentsOfFile: path),
            let cgImage = image.cgImage else {
        DispatchQueue.main.async {
          result([])
        }
        return
      }

      let ciImage = CIImage(cgImage: cgImage).oriented(forExifOrientation: Int32(self.cgImageOrientation(for: image.imageOrientation)))
      
      // We need to provide orientation because UIImage(contentsOfFile:) might strip it or we just process raw cgImage.
      // But image.imageOrientation can be converted to CGImagePropertyOrientation
      let orientation = 1 // Pixels are upright before detection.
      let options: [String: Any] = [
        CIDetectorImageOrientation: orientation,
        CIDetectorSmile: true,
        CIDetectorEyeBlink: true
      ]

      let features = detector.features(in: ciImage, options: options)
      var facesOutput: [[String: Any]] = []

      let imageWidth = ciImage.extent.width
      let imageHeight = ciImage.extent.height

      for feature in features {
        if let face = feature as? CIFaceFeature {
          
          // CoreImage uses Cartesian coordinate system (origin at bottom-left)
          // We need to convert it to standard top-left origin.
          var boundingBox = face.bounds
          boundingBox.origin.y = imageHeight - boundingBox.origin.y - boundingBox.size.height

          // Normalize
          let x = max(0, min(1, boundingBox.origin.x / imageWidth))
          let y = max(0, min(1, boundingBox.origin.y / imageHeight))
          let w = max(0, min(1 - x, boundingBox.size.width / imageWidth))
          let h = max(0, min(1 - y, boundingBox.size.height / imageHeight))

          // Convert boolean to probability (1.0 or 0.0)
          let smilingProb: Double = face.hasSmile ? 1.0 : 0.0
          // Left/Right eye closed means open probability is 0
          let leftEyeOpenProb: Double = face.leftEyeClosed ? 0.0 : 1.0
          let rightEyeOpenProb: Double = face.rightEyeClosed ? 0.0 : 1.0

          var output: [String: Any] = [
            "smilingProbability": smilingProb,
            "x": Double(x),
            "y": Double(y),
            "width": Double(w),
            "height": Double(h)
          ]
          // An undetected eye is unknown, not an open eye.
          if face.hasLeftEyePosition { output["leftEyeOpenProbability"] = leftEyeOpenProb }
          if face.hasRightEyePosition { output["rightEyeOpenProbability"] = rightEyeOpenProb }
          facesOutput.append(output)
        }
      }
      
      DispatchQueue.main.async {
        result(facesOutput)
      }
    }
  }
  
  private func cgImageOrientation(for uiOrientation: UIImage.Orientation) -> Int {
    switch uiOrientation {
    case .up: return 1
    case .down: return 3
    case .left: return 8
    case .right: return 6
    case .upMirrored: return 2
    case .downMirrored: return 4
    case .leftMirrored: return 5
    case .rightMirrored: return 7
    @unknown default: return 1
    }
  }
}
