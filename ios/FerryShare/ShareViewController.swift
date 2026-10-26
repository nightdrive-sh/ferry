import FerryKit
import SwiftUI
import UIKit

/// The share extension's entry: ShareView over the sharing app, at once, while the share loads behind it.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let box = SendableItems(items)
        let model = ShareSetup.model { await ShareLoader.load(box.items) }
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            // Uploads still running go on in the background session; nothing is cancelled here, and an end heard
            // from now on is told as a notification
            ShareSetup.uploader.detach()
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.start() }
    }
}

/// The share's items, handed to the loader: NSExtensionItem isn't Sendable, but only the loader reads them.
private struct SendableItems: @unchecked Sendable {
    let items: [NSExtensionItem]
    init(_ items: [NSExtensionItem]) { self.items = items }
}
