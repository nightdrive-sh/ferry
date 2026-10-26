import Photos
import SwiftUI
import UIKit

/// A file URL that a sheet can be presented for.
struct SheetFile: Identifiable {
    let url: URL
    var id: URL { url }
}

enum PhotoLibrary {
    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? { "Ferry may not add to your photos. Allow it in Settings › Apps › Ferry." }
    }

    /// Adds a photo or video. Asks only for add access: Ferry never reads the library.
    static func save(_ file: URL, type: String) async throws {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { throw Failure.denied }
        try await PHPhotoLibrary.shared().performChanges {
            if type.hasPrefix("video/") {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
            }
        }
    }
}

/// Save to Files: the system's picker, exporting a copy.
struct ExportSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

/// What the share sheet is opened with: a text, or a file already downloaded.
struct ShareItems: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// Share: the system's share sheet (ShareLink would need a file before the tap).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
