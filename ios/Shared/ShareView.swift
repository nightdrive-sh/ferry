import FerryKit
import SwiftUI

/// Ferry in the share sheet: what is being sent, the computers it can go to, and how the send is going. Built by both
/// the share extension and, under a debug launch argument, the app (so the UI tests can drive it against the mock).
struct ShareView: View {
    @Bindable var model: ShareModel
    let close: () -> Void

    /// How long "Sent to …" stays before the sheet closes by itself
    static let sentHold: Duration = .seconds(2)
    /// The sheet's slide up: a text to the only computer is often sent before it ends, and the hold is counted from
    /// when the sheet is up, or the confirmation is gone before anyone has looked at it
    static let sheetRise: Duration = .milliseconds(500)

    @State private var shownAt = ContinuousClock.now

    var body: some View {
        NavigationStack {
            Group {
                if case .sent(let to) = model.state { sent(to) } else { list }
            }
            .background(Theme.background)
            .navigationTitle("Ferry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(closesInBackground ? "Continue in Background" : "Close", action: close)
                }
            }
        }
        .task(id: model.state) {
            guard case .sent = model.state else { return }
            let until = max(ContinuousClock.now + Self.sentHold, shownAt + Self.sheetRise + Self.sentHold)
            try? await Task.sleep(until: until)
            if !Task.isCancelled { close() }
        }
    }

    /// The whole sheet turns into the confirmation: a row under the list went unseen when the send needed no tap
    private func sent(_ to: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(Theme.primary)
                .accessibilityHidden(true)
            Text("Sent to \(to)")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Theme.text)
            if let payloads = model.payloads {
                Text(ShareContent.summary(payloads)).font(.mono(.footnote)).foregroundStyle(Theme.dim)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            Section {
                HStack(spacing: 13) {
                    Image(systemName: model.sendsFiles ? "doc" : "text.alignleft")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                        .background(Theme.tile, in: .rect(cornerRadius: 11))
                    if let payloads = model.payloads {
                        Text(ShareContent.summary(payloads)).font(.mono(.body)).foregroundStyle(Theme.text).lineLimit(2)
                    } else {
                        Text("Preparing…").font(.mono(.body)).foregroundStyle(Theme.dim)
                    }
                }
                .listRowBackground(Theme.card)
            }
            switch model.state {
            case .noMachine:
                Section { message("Open Ferry to set up a computer first.") }
            case .nothingToSend:
                Section { message("Nothing Ferry can send.") }
            default:
                Section {
                    ForEach(model.rows) { row in machine(row) }
                } header: {
                    Text("Send to").textCase(.uppercase).font(.system(size: 12, weight: .semibold)).tracking(1).foregroundStyle(Theme.primary)
                }
            }
            status
        }
        .scrollContentBackground(.hidden)
    }

    /// Closing mid-upload leaves the files to iOS, which carries them on
    private var closesInBackground: Bool {
        if case .sending = model.state { return model.sendsFiles }
        return false
    }

    private func machine(_ row: ShareRow) -> some View {
        let answered = if case .answered = row.reply { true } else { false }
        return Button {
            Task { await model.pick(row.id) }
        } label: {
            HStack(spacing: 11) {
                Circle().fill(row.reply == .unreachable ? Theme.away : Theme.online)
                    .opacity(row.reply == .asking ? 0.35 : 1)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.machine.name).font(.mono(.body, weight: .medium)).foregroundStyle(Theme.text)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle).font(.mono(.footnote)).foregroundStyle(Theme.dim)
                    }
                }
                Spacer(minLength: 0)
                if row.reply == .asking { ProgressView().controlSize(.small) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!answered)
        .listRowBackground(Theme.card)
        .accessibilityLabel(row.machine.name)
        .accessibilityValue(row.subtitle)
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .sending(let p):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sending…").foregroundStyle(Theme.text)
                    ProgressView(value: p).tint(Theme.primary)
                }
                .listRowBackground(Theme.card)
            }
        case .failed(let why):
            Section {
                Text(why).foregroundStyle(Theme.away).listRowBackground(Theme.card)
                Button("Try again") { Task { await model.retry() } }
                    .foregroundStyle(Theme.primary)
                    .listRowBackground(Theme.card)
            }
        default:
            EmptyView()
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(Theme.dim).listRowBackground(Theme.card)
    }
}
