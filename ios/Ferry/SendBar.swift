import FerryKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The bar at the bottom, always on screen: T, Send Clipboard and +, with the computer they send to above them.
struct SendBar: View {
    @Bindable var model: FerryModel
    /// Called after a Send Clipboard that read the clipboard (the paste permission help, the first time)
    var afterClipboard: () -> Void = {}

    @State private var composing = false
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    @State private var photos: [PhotosPickerItem] = []

    /// The bar's side margin, which the list above shares so their edges line up.
    static let sideMargin: CGFloat = 14

    var body: some View {
        VStack(spacing: 10) {
            if nothingAnswers {
                Text("Can't reach your computers. Is Tailscale on?")
                    .font(.subheadline).foregroundStyle(Theme.away).multilineTextAlignment(.center)
            }
            MachineChip(model: model)
            HStack(spacing: 10) {
                circle("textformat", label: "Type a text") { composing = true }
                sendClipboard
                Menu {
                    Button("Photos", systemImage: "photo.on.rectangle") { pickingPhotos = true }
                    Button("Files", systemImage: "folder") { pickingFiles = true }
                } label: {
                    icon("plus")
                }
                .accessibilityLabel("Send photos or files")
            }
        }
        .padding(.horizontal, Self.sideMargin)
        .padding(.top, 28)
        .padding(.bottom, 6)
        .contentShape(Rectangle())   // a tap between the buttons stays in the bar, not on a row hidden under it
        .background {
            // The list fades out under the bar instead of showing through its gaps
            // Solid well above the machine chip, so the list's rows don't show through the buttons
            LinearGradient(stops: [.init(color: Theme.background.opacity(0), location: 0),
                                   .init(color: Theme.background.opacity(0.9), location: 0.12),
                                   .init(color: Theme.background, location: 0.22)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $composing) { ComposeSheet(model: model) }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, matching: .any(of: [.images, .videos]),
                      preferredItemEncoding: .current)
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            photos = []
            Task { await sendPhotos(picked) }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await sendFiles(urls) } }
        }
    }

    // MARK: Send Clipboard

    private var sendClipboard: some View {
        Button {
            Task {
                // Try again after a typed text or files sends those again; otherwise the clipboard, read now
                if case .failed = model.sendState, model.canRetry { return await model.retry() }
                let read = Pasteboard.hasContent   // an empty clipboard: iOS asked nothing, so no help about its setting
                await model.send(Pasteboard.payload())
                if read { afterClipboard() }
            }
        } label: {
            ZStack(alignment: .leading) {
                if case .sending(let p) = model.sendState {
                    GeometryReader { g in
                        Theme.onPrimary.opacity(0.18).frame(width: g.size.width * p)
                    }
                }
                sendLabel.frame(maxWidth: .infinity)
            }
            .frame(height: 58)
            .background(Theme.primary)
            .clipShape(.capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(model.target == nil || isSending)
        .accessibilityIdentifier("sendClipboard")
    }

    /// Every computer asked, and none answered: most likely Tailscale is off on the phone
    private var nothingAnswers: Bool {
        !model.list.machines.isEmpty && model.list.machines.allSatisfy { model.status[$0.url]?.reachable == false }
    }

    private var isSending: Bool {
        if case .sending = model.sendState { return true }
        return false
    }

    @ViewBuilder private var sendLabel: some View {
        switch model.sendState {
        case .idle:
            // Large text: "Send" when "Send Clipboard" doesn't fit on the bar's one row
            ViewThatFits(in: .horizontal) {
                Label("Send Clipboard", systemImage: "doc.on.clipboard").labelStyle(BarLabel())
                Label("Send", systemImage: "doc.on.clipboard").labelStyle(BarLabel())
            }
        case .sending:
            Label("Sending…", systemImage: "arrow.up.circle").labelStyle(BarLabel())
        case .sent(let to):
            Label("Sent to \(to)", systemImage: "checkmark").labelStyle(BarLabel())
        case .failed(let message):
            VStack(spacing: 1) {
                Text(message).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                Text("Try again").font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, 12)
        }
    }

    // MARK: Circles

    private func circle(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(Theme.accent)
            .frame(width: 58, height: 58)
            .glassEffect(.regular.interactive(), in: .circle)
            .contentShape(.circle)   // the whole circle takes the tap, not only the glyph's pixels
    }

    // MARK: Photos and files

    private func sendPhotos(_ picked: [PhotosPickerItem]) async {
        var payloads: [SendPayload] = []
        for item in picked {
            guard let file = try? await item.loadTransferable(type: PickedFile.self) else { continue }
            let type = item.supportedContentTypes.first ?? UTType(filenameExtension: file.url.pathExtension) ?? .data
            payloads.append(.file(file.url, name: file.url.lastPathComponent, type: type.preferredMIMEType ?? "application/octet-stream", clip: false))
        }
        await model.send(payloads)
    }

    private func sendFiles(_ urls: [URL]) async {
        var payloads: [SendPayload] = []
        for url in urls {
            // A picked file is outside the sandbox until accessed; a copy keeps it readable for the whole upload
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let copy = try? PickedFile.copy(url) else { continue }
            let type = UTType(filenameExtension: copy.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            payloads.append(.file(copy, name: copy.lastPathComponent, type: type, clip: false))
        }
        await model.send(payloads)
    }
}

/// A photo or video from the picker, as a file in a folder of its own (keeping the name the library gives it).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            PickedFile(url: try copy(received.file))
        }
    }

    static func copy(_ file: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: dest)
        return dest
    }
}

/// Send Clipboard's label: icon and text in the button's own colours.
private struct BarLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.font(.system(size: 20, weight: .semibold))
            configuration.title.font(.system(.title3, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(Theme.onPrimary)
    }
}
