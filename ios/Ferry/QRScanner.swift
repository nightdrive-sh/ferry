import SwiftUI
import VisionKit

/// The camera, looking for a QR code: Add Device on a computer running Ferry shows one with its address.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }   // only once the view is on screen
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let value = code.payloadStringValue else { continue }
                done = true
                scanner.stopScanning()
                found(value)
            }
        }
    }
}
