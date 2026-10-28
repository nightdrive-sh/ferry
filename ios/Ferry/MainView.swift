import FerryKit
import QuickLook
import SwiftUI
import UIKit

/// Ferry's one screen: the title row, what the computers sent, and (from SendBar) sending.
struct MainView<Bar: View>: View {
    @Bindable var model: FerryModel
    /// A line from elsewhere (a tapped notification's "Copied")
    var toast: Toast?
    var openSettings: () -> Void = {}
    /// Leaves the demo; set while the computers are the demo's pretend ones, which a banner then says
    var leaveDemo: (() -> Void)?
    /// The demo while it runs, for its banner's hint (read here: a view follows its changes, the app's body doesn't)
    var demo: Demo?
    @ViewBuilder var bar: () -> Bar

    @Environment(\.openURL) private var openURL
    @State private var confirmClear = false
    @State private var preview: URL?
    @State private var export: SheetFile?
    @State private var share: ShareItems?
    @State private var note: String?
    @State private var thumbnails: [String: UIImage] = [:]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in   // the ages move on while the screen is open
          ScrollViewReader { scroller in
            List {
                Section {
                    if model.received.isEmpty, !model.hasPolled {
                        // A slow connection takes seconds to answer: "nothing here" would be wrong until it does
                        HStack(spacing: 10) {
                            ProgressView().tint(Theme.dim)
                            Text("Checking your computers…").font(.subheadline).foregroundStyle(Theme.dim)
                        }
                        .padding(.vertical, 6)
                    } else if model.received.isEmpty {
                        Text("Nothing here yet. What your computers send shows up here.")
                            .font(.subheadline).foregroundStyle(Theme.dim).padding(.vertical, 6)
                    }
                    ForEach(model.received) { r in
                        ReceivedRow(received: r, isNew: model.isNew(r), now: context.date, thumbnail: thumbnails[r.id],
                                    isLoading: model.loading.contains(r.id)) { act($0, r) }
                            .listRowBackground(background(r))
                            .listRowSeparatorTint(Theme.hairline)
                            .listRowInsets(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 14))
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 63 }
                            .swipeActions(edge: .trailing) {
                                Button("Remove", systemImage: "trash", role: .destructive) { act(.remove, r) }
                            }
                            // Again when its computer answers again: a thumbnail asked for while it slept stays empty
                            .task(id: "\(r.id) \(model.status[r.machine]?.reachable == true)") { await loadThumbnail(r) }
                    }
                } header: {
                    // The title row lives in the section header, not in a row: an inset list clips its rows to the
                    // card's rounded corners, which cut into the icon. Flush with the card: the icon at its left edge,
                    // the online count at its right.
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if let leaveDemo { DemoBanner(step: demo?.step ?? .tryIt, leave: leaveDemo) }
                        sectionTitle.padding(.horizontal, 16)
                    }
                    .padding(.top, 6)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .contentMargins(.top, 0, for: .scrollContent)   // the inset list's own top gap, under the status bar's
            .contentMargins(.horizontal, SendBar.sideMargin, for: .scrollContent)   // as wide as the buttons below
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .refreshable { await model.refresh() }
            .onChange(of: model.highlighted) { _, id in
                guard let id else { return }
                withAnimation { scroller.scrollTo(id, anchor: .center) }
                Task {   // a tapped notification's item stands out for a moment, then looks like the rest
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { if model.highlighted == id { model.clearHighlight() } }
                }
            }
          }
        }
        .onChange(of: toast) { _, t in if let t { show(t.text) } }
        .safeAreaInset(edge: .bottom, spacing: 0) { bar() }
        .overlay(alignment: .top) { noteView }
        .quickLookPreview($preview)
        .sheet(item: $export) { ExportSheet(url: $0.url) }
        .sheet(item: $share) { ShareSheet(items: $0.items).presentationDetents([.medium, .large]) }
        .confirmationDialog("Clear everything your computers sent?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { Task { await model.clearReceived() } }
        } message: {
            Text("Files already saved stay where they are.")
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            Image("FerryIcon").resizable().frame(width: 36, height: 36).clipShape(.rect(cornerRadius: 9))
                .accessibilityHidden(true)
            Text("Ferry").font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.accent)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            // Settings where people look for them (Jari: nobody would think to tap the logo). The computers' state is
            // in the machine chip below and in Settings, so the header no longer counts them; VoiceOver still hears it
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityValue(model.onlineText)
        }
    }

    private func background(_ r: Received) -> Color {
        if model.highlighted == r.id { return Theme.tile }
        return model.isNew(r) ? Theme.tile.opacity(0.55) : Theme.card
    }


    private var sectionTitle: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("RECEIVED").font(.system(size: 12, weight: .semibold)).tracking(1).foregroundStyle(Theme.primary)
            Spacer()
            if !model.received.isEmpty {
                Button("Clear") { confirmClear = true }.font(.subheadline).foregroundStyle(Theme.dim)
            }
        }
        .textCase(nil)
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var noteView: some View {
        if let note {
            Text(note).font(.subheadline).foregroundStyle(Theme.text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Actions

    private func act(_ action: RowAction, _ r: Received) {
        switch action {
        case .copy:
            Pasteboard.copy(r.item.text ?? "")
            // A code or a password leaves the list once copied (docs/protocol.md › Codes and passwords), and its row
            // with it, so the note says it was copied
            if r.item.isSecret { show("Copied") }
            Task { await model.copied(r) }
        case .openLink:
            if let s = r.item.text?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: s) { openURL(url) }
        case .remove:
            Task { await model.remove(r) }
        case .share where r.item.kind == .text:
            share = ShareItems(items: [r.item.text ?? ""])
        case .open, .saveToPhotos, .saveToFiles, .share:
            withFile(r) { url in
                switch action {
                case .open: preview = url
                case .saveToFiles: export = SheetFile(url: url)
                case .share: share = ShareItems(items: [url])
                default:
                    do {
                        try await PhotoLibrary.save(url, type: r.item.type ?? "")
                        show("Saved to Photos")
                    } catch { show(error.localizedDescription) }
                }
            }
        }
    }

    /// The file downloaded first: Quick Look, the share sheet and the exporter all need it on the phone.
    private func withFile(_ r: Received, _ then: @escaping @MainActor (URL) async -> Void) {
        Task {
            do {
                await then(try await model.download(r))
            } catch let e as FerryError {
                show(e.message)
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func show(_ text: String) {
        withAnimation { note = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if note == text { note = nil } }
        }
    }

    private func loadThumbnail(_ r: Received) async {
        guard thumbnails[r.id] == nil, r.item.kind == .file, (r.item.type ?? "").hasPrefix("image/"),
              (r.item.size ?? 0) < 30_000_000,   // a thumbnail isn't worth a huge download
              let url = try? await model.download(r),
              let image = await UIImage(contentsOfFile: url.path(percentEncoded: false))?.byPreparingThumbnail(ofSize: CGSize(width: 150, height: 150))
        else { return }
        thumbnails[r.id] = image
    }
}
