import SwiftUI
#if targetEnvironment(macCatalyst)
/// VisionKit's scanner doesn't exist on Mac Catalyst — the Mac pairs by the pasted link or the form instead.
struct QRScannerView: View {
    var onScan: (String) -> Void
    var body: some View {
        ContentUnavailableView("No camera scanner on Mac", systemImage: "link",
                               description: Text("Use “Copy link” in the Host app's menu and paste it below, or pick the Mac from the list."))
    }
}
#else
import VisionKit

/// Camera QR scanner (VisionKit). Unavailable in the simulator; the pairing form still works.
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            let host = UIHostingController(rootView: ContentUnavailableView("Camera unavailable", systemImage: "camera.fill", description: Text("Enter the token by hand instead.")))
            return host
        }
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var fired = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !fired else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    fired = true
                    dataScanner.stopScanning()
                    onScan(payload)
                    return
                }
            }
        }
    }
}
#endif
