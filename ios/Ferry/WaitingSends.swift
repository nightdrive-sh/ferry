import BackgroundTasks
import FerryKit
import UIKit
import UserNotifications

/// Sends that wait for a computer that is asleep or off, sent from the background once it is back (docs/protocol.md ›
/// Clients › Sends that wait): when the computer's silent "awake" push wakes the app, and when iOS gives it a
/// background app refresh, asked for while anything waits. On screen, the poll finds the computer awake by itself.
@MainActor final class WaitingSends {
    static let shared = WaitingSends()
    /// Info.plist's BGTaskSchedulerPermittedIdentifiers
    static let refreshTask = "fi.feature.ferry.waiting"
    /// The soonest iOS is asked for a background refresh after the last
    static let refreshAfter: TimeInterval = 15 * 60

    /// Set by FerryApp before launch ends: the real computers' model, never the demo's
    var model: FerryModel?

    /// At launch, before it ends (iOS's rule for BGTaskScheduler)
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in await WaitingSends.shared.refresh(task) }
        }
    }

    /// Whenever the app leaves the screen: a background refresh while anything waits, none otherwise
    func schedule() {
        guard let model, !model.waiting.isEmpty else {
            return BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTask)
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshAfter)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// A computer's "awake" push (the relay sends it as a background push: `a`, the relay address it came through,
    /// names the computer). Only that computer is asked, and only if something waits for it.
    func awake(_ info: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let model, let address = info["a"] as? String,
              let machine = PushCenter.current?.registrar.machine(forAddress: address),
              model.waitingFor.contains(machine) else { return .noData }
        let before = model.waiting.count
        await deliver(to: [machine])
        return model.waiting.count < before ? .newData : .noData
    }

    private func refresh(_ task: BGTask) async {
        let work = Task { await deliver(to: model?.waitingFor ?? []) }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: true)
        schedule()   // what is still waiting asks for the next one
    }

    /// Asks the computers what waits for them; those that answer take it (FerryModel.refresh). The background task
    /// keeps the app running while an upload finishes, until iOS's time is up.
    private func deliver(to machines: Set<URL>) async {
        guard let model, !machines.isEmpty else { return }
        let id = UIApplication.shared.beginBackgroundTask(withName: "Waiting sends")
        defer { UIApplication.shared.endBackgroundTask(id) }
        await model.refresh(only: machines)
    }

    /// A waiting send went, or was refused: said in a notification while Ferry isn't on screen (on screen, the row
    /// leaving says it). A code's or a password's is named only as such.
    static func notify(_ send: QueuedSend, _ outcome: QueuedOutcome) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        switch outcome {
        case .delivered:
            content.title = String(localized: "Delivered to \(send.machineName)")
            let age = Age.short(Date.now.timeIntervalSince(send.time))
            content.body = age == "now" ? send.what : String(localized: "\(send.what) · sent \(age) ago")
        case .refused(let said):
            content.title = String(localized: "Couldn't send to \(send.machineName)")
            content.body = "\(send.what): \(said)"
        }
        content.userInfo = ["delivered": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "waiting-\(send.id)", content: content,
                                                                     trigger: nil))
    }
}
