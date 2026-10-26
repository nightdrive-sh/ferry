import FerryKit
import SwiftUI

/// From the title row: the computers, adding one, the paste permission, where to get help and the version.
struct SettingsView: View {
    @Bindable var model: FerryModel
    var push: PushCenter
    /// Set in the demo: its computers are pretend, so there is no adding one, only leaving
    var leaveDemo: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var adding = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(TargetRule.order(model.list.machines, status: model.status), id: \.url) { m in
                        row(m)
                            .swipeActions(edge: .trailing) {
                                Button("Forget", systemImage: "trash", role: .destructive) { Task { await model.forget(m.url) } }
                            }
                            .contextMenu {
                                if !m.isSetup { Button("Use for Setup", systemImage: "star") { model.makeSetup(m.url) } }
                                Button("Forget", systemImage: "trash", role: .destructive) { Task { await model.forget(m.url) } }
                            }
                            .listRowBackground(Theme.card)
                    }
                    if let leaveDemo {
                        Button("Leave Demo", systemImage: "rectangle.portrait.and.arrow.right") {
                            dismiss()
                            leaveDemo()
                        }
                        .accessibilityIdentifier("settingsLeaveDemo")
                        .listRowBackground(Theme.card)
                    } else {
                        Button("Add a Computer", systemImage: "plus") { adding = true }.listRowBackground(Theme.card)
                    }
                } header: {
                    Text("Computers")
                } footer: {
                    if leaveDemo != nil {
                        Text("These computers are pretend: nothing leaves the phone. To use Ferry, set it up with a computer running Ferry.")
                    } else {
                        Text("Ferry finds your other computers through the setup one. Forget takes a computer off all your devices until you bring it back on one of your computers. A computer that hasn't answered for 7 days leaves this list.")
                    }
                }
                notifications
                Section {
                    NavigationLink("Paste Permission") { PasteHelpView() }.listRowBackground(Theme.card)
                }
                about
                Section {
                    LabeledContent("Version", value: version).listRowBackground(Theme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $adding) { SetupView(model: model, adding: true) { adding = false } }
            .onChange(of: model.isSetUp) { _, setUp in if !setUp { dismiss() } }   // the last one forgotten: setup again
        }
    }

    /// Where Ferry comes from and who answers: the website, the support address and the privacy policy (which App
    /// Review wants reachable from inside the app).
    private var about: some View {
        Section {
            link("Ferry Website", "globe", "https://nightdrive.sh/ferry")
            link("Email Support", "envelope", "mailto:hello@nightdrive.sh")
            link("Privacy Policy", "hand.raised", "https://nightdrive.sh/ferry/privacy")
        } header: {
            Text("About")
        } footer: {
            Text(verbatim: "nightdrive.sh/ferry · hello@nightdrive.sh")
        }
    }

    private func link(_ title: LocalizedStringKey, _ symbol: String, _ address: String) -> some View {
        Link(destination: URL(string: address)!) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.dim)
            }
        }
        .listRowBackground(Theme.card)
    }

    private var notifications: some View {
        Section {
            Toggle("Notifications", isOn: Binding(get: { push.enabled && push.authorization == .authorized },
                                                  set: { on in Task { await push.setEnabled(on) } }))
                .disabled(push.authorization == .denied)
                .tint(Theme.primary)
                .listRowBackground(Theme.card)
            if push.authorization == .denied {
                Button("Allow in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .listRowBackground(Theme.card)
            }
        } footer: {
            // The demo's computers have no notification key, yet its reply notifies
            let silent = leaveDemo != nil ? [] : model.list.machines.filter { model.status[$0.url]?.reachable == true && model.status[$0.url]?.push == nil }
            if push.authorization == .denied {
                Text("Notifications are off for Ferry in iOS Settings.")
            } else if !silent.isEmpty {
                Text("\(silent.map(\.name).formatted(.list(type: .and))) can't send notifications: it needs python3-cryptography.")
            } else {
                Text("A notification when a computer sends you something. Tapping it opens the item, and copies a text.")
            }
        }
    }

    private func row(_ m: KnownMachine) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(.mono(.body, weight: .medium)).foregroundStyle(Theme.text)
                let used = TargetRule.usedLabel(model.status[m.url])
                Text(used.isEmpty ? m.url.host() ?? "" : used).font(.mono(.footnote)).foregroundStyle(Theme.dim)
            }
            Spacer()
            if m.isSetup {
                Text("setup").font(.mono(.caption, weight: .medium)).foregroundStyle(Theme.primary)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.tile, in: .capsule)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
