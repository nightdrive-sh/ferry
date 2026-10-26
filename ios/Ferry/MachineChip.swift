import FerryKit
import SwiftUI

/// Where a send goes, above Send Clipboard: the computer in use. With more than one, a tap opens iOS's own menu for
/// another, for one send; a hand pick is outlined until that send.
struct MachineChip: View {
    @Bindable var model: FerryModel

    private var many: Bool { model.list.machines.count > 1 }

    var body: some View {
        if many {
            Menu {
                Section("Send to") {
                    ForEach(TargetRule.order(model.list.machines, status: model.status), id: \.url) { m in
                        // A menu item reads its label as icon, title and subtitle
                        Button { model.manual = m.url } label: {
                            if m.url == model.target { Image(systemName: "checkmark") }
                            Text(m.name)
                            Text(TargetRule.usedLabel(model.status[m.url]))
                        }
                        .disabled(model.status[m.url]?.reachable == false)
                    }
                }
            } label: { chip }
            // A new menu for each computer: the closing menu morphs back into the label at its old width, and a longer
            // name was cut off at both ends (glass gone) until that finished
            .id(model.target)
            .accessibilityLabel("Send to \(model.name(of: model.target)), change computer")
        } else {
            chip.accessibilityLabel("Sends to \(model.name(of: model.target))")
        }
    }

    private var chip: some View {
        HStack(spacing: 7) {
            Circle().fill(model.target.flatMap { model.status[$0] }?.reachable == false ? Theme.away : Theme.online)
                .frame(width: 8, height: 8)
            Text(model.name(of: model.target)).font(.mono(.subheadline, weight: .medium)).foregroundStyle(Theme.text)
            if many {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 34)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(.capsule)
        .overlay {
            if model.manual != nil { Capsule().strokeBorder(Theme.primary, lineWidth: 1.5) }
        }
    }
}
