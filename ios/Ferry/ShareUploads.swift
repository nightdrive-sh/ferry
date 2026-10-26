import FerryKit
import Foundation

/// The share sheet's uploads that end after its extension is gone: iOS wakes the app to hear them. A failure becomes a
/// notification ("Couldn't send photo.jpg to MacBook"); success says nothing, the computer shows it.
@MainActor
final class ShareUploads {
    static let shared = ShareUploads()

    private var session: URLSession?
    private var completion: (() -> Void)?

    func reconnect(completion: @escaping () -> Void) {
        self.completion = completion
        guard session == nil else { return }
        let finisher = UploadFinisher(onFailure: ShareSetup.notifyFailure, onAllDone: {
            Task { @MainActor in ShareUploads.shared.finishEvents() }
        })
        session = URLSession(configuration: BackgroundUploader.configuration(appGroup: FerryApp.appGroup),
                             delegate: finisher, delegateQueue: nil)
    }

    /// iOS waits for this before it suspends the app again
    private func finishEvents() {
        completion?()
        completion = nil
    }
}
