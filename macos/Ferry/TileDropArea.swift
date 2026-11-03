import AppKit
import SwiftUI

/// One drop target over all of the device tiles, which picks the tile from where the pointer is.
///
/// AppKit rather than SwiftUI's onDrop, for two reasons. A drop target per tile made the tiles flicker: the drag left
/// one target and entered the next at every gap, and in between the popover thought the drag had gone. And onDrop
/// hands over item providers, not the drag's own pasteboard: reading `NSPasteboard(name: .drag)` instead found an
/// earlier drag's files whenever the source used a pasteboard of its own, as a Dock stack does, and sent those.
/// Here every drop reads `draggingPasteboard`, the one that belongs to this drag.
struct TileDropArea: NSViewRepresentable {
    /// The tiles' frames in this view's coordinates (top-left origin), by device id
    let frames: [String: CGRect]
    /// Whether a tile takes a drop now
    let open: (String) -> Bool
    /// The tile the drag is over, nil when none: what the tiles highlight
    @Binding var targeted: String?
    /// The drag is anywhere over the area, so the popover keeps showing the tiles
    @Binding var inside: Bool
    let drop: (String, DroppedFiles) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.registerForDraggedTypes(DroppedFiles.pasteboardTypes)
        return view
    }

    func updateNSView(_ view: DropView, context: Context) {
        view.area = self
    }

    final class DropView: NSView {
        var area: TileDropArea?

        // SwiftUI's coordinates, so the tiles' frames need no flipping
        override var isFlipped: Bool { true }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard DroppedFiles.canTake(sender.draggingPasteboard) else { return [] }
            area?.inside = true
            return follow(sender)
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard DroppedFiles.canTake(sender.draggingPasteboard) else { return [] }
            return follow(sender)
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            leave()
        }

        override func draggingEnded(_ sender: any NSDraggingInfo) {
            leave()
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer { leave() }
            guard let area, let id = area.targeted, area.open(id),
                  let dropped = DroppedFiles.take(sender.draggingPasteboard) else { return false }
            area.drop(id, dropped)
            return true
        }

        /// The tile under the pointer becomes the target. Over a gap between tiles the one highlighted stays, so
        /// crossing from tile to tile doesn't flash; a drop there goes where the highlight says.
        private func follow(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard let area else { return [] }
            let point = convert(sender.draggingLocation, from: nil)
            if let hit = area.frames.first(where: { $0.value.contains(point) })?.key {
                let id = area.open(hit) ? hit : nil
                if area.targeted != id { area.targeted = id }
            }
            guard let id = area.targeted, area.open(id) else { return [] }
            return .copy
        }

        private func leave() {
            guard let area else { return }
            if area.targeted != nil { area.targeted = nil }
            if area.inside { area.inside = false }
        }
    }
}
