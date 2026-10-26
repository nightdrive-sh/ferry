import SwiftUI

/// Asked once: after the first computer is set up, or on the first launch of a phone set up before notifications existed.
struct NotificationsPrompt: View {
    var turnOn: () -> Void
    var notNow: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bell.badge").font(.system(size: 44)).foregroundStyle(Theme.primary).padding(.top, 28)
            Text("Notifications").font(.title2.bold()).foregroundStyle(Theme.accent)
            Text("Get a notification when a computer running Ferry sends you something.")
                .font(.body).foregroundStyle(Theme.dim).multilineTextAlignment(.center).padding(.horizontal, 24)
            Spacer(minLength: 8)
            Button(action: turnOn) {
                Text("Turn On Notifications").font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .foregroundStyle(Theme.onPrimary).background(Theme.primary, in: .capsule)
            }
            .buttonStyle(.plain)
            Button("Not Now", action: notNow).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .interactiveDismissDisabled()
    }
}
