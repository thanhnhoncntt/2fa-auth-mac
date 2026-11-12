// Scans a QR code anywhere on screen: any app, any Chrome profile. Uses macOS's own ⌘⇧4 region picker
// (/usr/sbin/screencapture -i) and Vision's barcode reader. The screenshot never leaves this Mac and is deleted
// as soon as it has been read.
import AppKit
import Vision

enum ScreenScanner {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    static func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// nil when the user pressed Esc.
    static func captureRegion() async -> CGImage? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let finished: Bool = await withCheckedContinuation { done in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", "-o", file.path] // interactive, no sound, no window shadow
            process.terminationHandler = { _ in done.resume(returning: true) }
            do { try process.run() } catch { done.resume(returning: false) }
        }
        // Read into memory before the file is deleted.
        guard finished, let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func readQRCodes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}
