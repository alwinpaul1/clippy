import Cocoa
import FlutterMacOS
import Vision

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Hide the "clippy" window-title text (keep the traffic-light controls).
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    // Closing only hides the window (window_manager intercepts it), so keep the
    // instance alive when it does close.
    self.isReleasedWhenClosed = false

    RegisterGeneratedPlugins(registry: flutterViewController)
    ClipVision.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  // Required by window_manager for correct show/hide ordering.
  override public func order(
    _ place: NSWindow.OrderingMode, relativeTo otherWin: Int
  ) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}

/// On-device image understanding for search ("clippy/vision"): the text in
/// a screenshot (Vision OCR) and what a photo shows (Vision's built-in image
/// classifier). Runs on a background queue; nothing leaves the Mac.
enum ClipVision {
  private static let queue = DispatchQueue(label: "clippy.vision", qos: .utility)

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "clippy/vision", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "analyze" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let data = (args["bytes"] as? FlutterStandardTypedData)?.data
      else {
        result(FlutterError(code: "args", message: "bytes missing", details: nil))
        return
      }
      queue.async {
        let out = analyze(data)
        DispatchQueue.main.async {
          if let out = out {
            result(out)
          } else {
            result(FlutterError(code: "vision", message: "analysis failed", details: nil))
          }
        }
      }
    }
  }

  private static func analyze(_ data: Data) -> [String: Any]? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }

    let text = VNRecognizeTextRequest()
    text.recognitionLevel = .accurate
    text.usesLanguageCorrection = true
    if #available(macOS 13.0, *) {
      text.automaticallyDetectsLanguage = true
    }
    let classify = VNClassifyImageRequest()

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([text, classify])
    } catch {
      return nil
    }
    // Lines top to bottom, as the screenshot reads.
    let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    // The classifier scores ~1300 labels; keep the confident ones, with
    // "_" spelled as a space so "credit_card" matches a search for "card".
    let labels = (classify.results ?? [])
      .filter { $0.confidence >= 0.35 }
      .prefix(12)
      .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    return ["text": lines.joined(separator: "\n"), "labels": Array(labels)]
  }
}
