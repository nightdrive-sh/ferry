import FerryKit
import SwiftUI

/// A computer's link opened from outside, nightdrive.sh's add page (Add Device's QR code in the Camera). Each opening is
/// tried, even of the same link again.
struct OpenedLink: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// The first launch, and Settings › Add a Computer: a computer running Ferry, by its QR code or its name.
struct SetupView: View {
    @Bindable var model: FerryModel
    /// Adding one more beside the setup computer (from settings)
    var adding = false
    /// Connects to that computer as soon as it is shown, as if its QR code had been scanned
    var link: OpenedLink?
    var done: () -> Void = {}
    /// The demo's way in, on the first launch only: "Try without a computer"
    var tryDemo: (() -> Void)?

    @State private var scanning = false
    @State private var typing = false
    @State private var name = ""
    @State private var checking = false
    @State private var problem: String?
    /// The computer's short name while setup keeps asking one that doesn't answer yet (just set up, getting its
    /// HTTPS certificate)
    @State private var waitingFor: String?
    @State private var attempt: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image("FerryIcon").resizable().frame(width: 88, height: 88).clipShape(.rect(cornerRadius: 20))
            VStack(spacing: 8) {
                Text(adding ? "Add a Computer" : "Ferry").font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.accent)
                Text("Send the clipboard, text and files to your computers, over Tailscale.")
                    .font(.body).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            Spacer()
            if typing { nameField }
            if let problem {
                Text(problem).font(.subheadline).foregroundStyle(Theme.away).multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if let waitingFor {
                waiting(waitingFor)
            } else if checking {
                ProgressView("Checking…").tint(Theme.primary).foregroundStyle(Theme.dim)
            } else {
                VStack(spacing: 12) {
                    big("Scan QR Code", "qrcode.viewfinder", primary: true) { problem = nil; scanning = true }
                    if !typing { big("Type a Computer's Name", "keyboard", primary: false) { typing = true; nameFocused = true } }
                    if let tryDemo {
                        Button("Try without a computer", action: tryDemo)
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                            .frame(height: 44)
                    }
                }
                .padding(.horizontal, 20)
            }
            VStack(spacing: 6) {
                Text("The QR code is under Add Device on a computer running Ferry.")
                    .font(.footnote).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                // Someone new has no computer running Ferry yet, and nothing here said where to get it (Jari)
                Link("Get Ferry for your computer", destination: URL(string: "https://nightdrive.sh/ferry")!)
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.primary)
                    .frame(minHeight: 32)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .sheet(isPresented: $scanning) { scanner }
        .task(id: link) {
            if let link { use(link.url.absoluteString) }
        }
        .onDisappear { attempt?.cancel() }
    }

    private func waiting(_ machine: String) -> some View {
        VStack(spacing: 10) {
            ProgressView().tint(Theme.primary)
            Text("Waiting for \(machine)…").font(.headline).foregroundStyle(Theme.accent)
            Text("A computer just set up to run Ferry gets its HTTPS certificate first, which can take up to a minute.")
                .font(.subheadline).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
            Button("Cancel", action: cancel)
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                .frame(height: 44)
        }
        .padding(.horizontal, 24)
    }

    private var nameField: some View {
        HStack {
            TextField("Computer name", text: $name)
                .font(.mono(.body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($nameFocused)
                .onSubmit { use(name) }
            Button("Connect") { use(name) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var scanner: some View {
        if QRScanner.isAvailable {
            QRScanner { value in
                scanning = false
                use(value)
            }
            .ignoresSafeArea()
        } else {
            VStack(spacing: 12) {
                Image(systemName: "camera").font(.largeTitle).foregroundStyle(Theme.dim)
                Text("This device can't scan QR codes. Type the computer's name instead.")
                    .foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                Button("OK") { scanning = false; typing = true }
            }
            .padding(32)
            .presentationDetents([.medium])
        }
    }

    private func big(_ title: String, _ symbol: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .foregroundStyle(primary ? Theme.onPrimary : Theme.accent)
                .background(primary ? Theme.primary : Theme.tile, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: Connecting

    private func cancel() {
        attempt?.cancel()
        checking = false
        waitingFor = nil
    }

    private func use(_ input: String) {
        problem = nil
        cancel()
        attempt = Task {
            checking = true
            // A cancelled try leaves the state alone: Cancel has reset it, or a newer link's try owns it
            defer { if !Task.isCancelled { checking = false; waitingFor = nil } }
            switch SetupAddress.parse(input) {
            case .url(let url):
                await connect(url)
            case .bareName(let bare):
                let resolved = await NameResolver.fullName(for: bare)
                guard !Task.isCancelled else { return }
                guard let full = resolved, case .url(let url) = SetupAddress.parse(full) else {
                    problem = "Type the full name, like computer.tailXXXX.ts.net"
                    return
                }
                await connect(url)
            case .invalid:
                problem = "That isn't a computer's name or address."
            }
        }
    }

    private func connect(_ url: URL) async {
        do {
            try await model.setUp(url, asSetup: !adding, patience: FerryModel.setupPatience) {
                waitingFor = SetupAddress.shortName(url)
            }
            done()
        } catch {
            // Cancel under "Waiting for …", or a newer link: nothing to say
            guard !(error is CancellationError), !Task.isCancelled else { return }
            problem = "Can't reach that computer. Is Tailscale on, the computer awake, and Ferry running on it?"
        }
    }
}
