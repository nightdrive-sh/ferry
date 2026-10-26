import FerryKit
import SwiftUI
import UIKit
import UserNotifications

/// "Try without a computer": the app on DemoBackend's two pretend computers, for App Review and anyone curious before
/// setting anything up. It lives only in memory: nothing goes into the App Group (the share extension never sees the
/// pretend computers), and the next launch starts at setup again.
@MainActor @Observable final class Demo {
    /// How far the visitor has got, for the hint under the banner
    enum Step { case tryIt, sent, answered }

    let model: FerryModel
    private(set) var step = Step.tryIt
    /// Held from the first send until MacBook's reply is in: the reply is timed inside the app, so a phone locked at
    /// once would suspend Ferry first, and the reply and its notification would wait for the next unlock
    @ObservationIgnored private var holding = UIBackgroundTaskIdentifier.invalid
    private static let suite = "fi.feature.ferry.demo"
    private static let notification = "demo-reply"

    private init(model: FerryModel) { self.model = model }

    /// Set up with the demo's MacBook, as setup does with a real computer's address. `sent` hears of the first send,
    /// and `arrived` of what MacBook sends back after it.
    static func start(sent: @escaping @MainActor @Sendable () -> Void,
                      arrived: @escaping @MainActor @Sendable (Received) async -> Void) async -> Demo {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let backend = DemoBackend(photo: photo(), onFirstSend: { await sent() }, onArrival: { r in await arrived(r) })
        let model = FerryModel(backend: backend, store: MachineStore(defaults: defaults))
        try? await model.setUp(DemoBackend.macBook)   // DemoBackend always answers its own computers
        return Demo(model: model)
    }

    func sent() {
        step = .sent
        guard holding == .invalid else { return }
        holding = UIApplication.shared.beginBackgroundTask(withName: "Demo reply") { [weak self] in self?.letGo() }
    }

    /// After the reply is in Received and its notification is out.
    func answered() {
        step = .answered
        letGo()
    }

    func leave() {
        letGo()
        UserDefaults(suiteName: Self.suite)?.removePersistentDomain(forName: Self.suite)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notification])
    }

    private func letGo() {
        guard holding != .invalid else { return }
        UIApplication.shared.endBackgroundTask(holding)
        holding = .invalid
    }

    /// What a computer's notification would say (bin/ferry's title and body), made here: no computer, no relay.
    /// `notice` is what the notification extension hands a tap, so a tap opens the item and copies the text.
    static func notify(_ r: Received) async {
        let content = UNMutableNotificationContent()
        content.title = r.machineName
        content.body = r.item.text ?? r.item.name ?? ""
        content.sound = .default
        content.userInfo = ["demo": true,
                            "notice": ["id": r.item.id, "kind": r.item.kind.rawValue, "text": r.item.text ?? ""]]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notification, content: content, trigger: nil))
    }

    /// The picture MacBook holds: Ferry's icon on its violet, as a screenshot would be.
    private static func photo() -> Data {
        let size = CGSize(width: 1200, height: 800)
        return UIGraphicsImageRenderer(size: size).pngData { c in
            let violet = UIColor(Theme.primary).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            violet.setFill()
            c.fill(CGRect(origin: .zero, size: size))
            if let icon = UIImage(named: "FerryIcon") {
                let side: CGFloat = 320
                let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
                UIBezierPath(roundedRect: rect, cornerRadius: side * 0.225).addClip()
                icon.draw(in: rect)
            }
        }
    }
}

/// The demo's mark under the title row: what it is, the way out, and what to try until MacBook has answered (Jari:
/// nothing said what to do, nor where a send went, since Received lists only what the computers send).
struct DemoBanner: View {
    var step: Demo.Step
    var leave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            banner
            if let hint {
                Label(hint.text, systemImage: hint.symbol)
                    .font(.subheadline).foregroundStyle(Theme.dim)
                    .labelStyle(HintLabelStyle())
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("demoHint")
            }
        }
        .animation(.default, value: step)
    }

    private var hint: (text: LocalizedStringKey, symbol: String)? {
        switch step {
        case .tryIt: ("Send MacBook something: copy a text and tap Send Clipboard, or use Aa or +.", "lightbulb")
        case .sent: ("Sent to MacBook. Received is for what your computers send you, and MacBook answers in a moment.", "checkmark")
        case .answered: nil
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Text("DEMO").font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(Theme.onPrimary)
                .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.primary, in: .capsule)
            Text("Two pretend computers").font(.subheadline).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Button("Leave Demo", action: leave).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
        }
        .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 9)
        .background(Theme.tile, in: .capsule)
        .accessibilityElement(children: .contain)
    }
}

/// The hint's symbol in the accent colour, at the first line's height.
private struct HintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(Theme.primary)
            configuration.title
        }
    }
}
