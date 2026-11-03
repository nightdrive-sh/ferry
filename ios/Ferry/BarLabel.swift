import SwiftUI

/// Send Clipboard's label: icon and text in the button's own colours.
struct BarLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.font(BarLabel.iconFont)
            configuration.title.font(BarLabel.textFont).lineLimit(1)
        }
        .foregroundStyle(Theme.onPrimary)
    }

    static let iconFont = Font.system(size: 20, weight: .semibold)
    static let textFont = Font.system(.title3, weight: .semibold)
}

/// "Sent to …" / "Waiting for …" on Send Clipboard. A computer's name can be longer than the button
/// ("Jari's MacBook Pro"), so the label steps down until it fits, inside the capsule's rounded ends: the whole line,
/// then the name cut at its end, then the verb alone ("Waiting").
struct BarStatus: View {
    enum Kind { case sent, waiting }
    let kind: Kind
    let name: String

    /// The least of the name worth showing: about "Jari…"; less is a lone "…", and the verb alone says more
    private static let nameRoom: CGFloat = 44

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Fits: one text, as before (the UI tests find it as "Sent to MacBook")
            Label { Text(line) } icon: { Image(systemName: symbol) }.labelStyle(BarLabel())
            // Cut: VoiceOver reads the whole line, not what shows (a Group's modifiers reach each of its views)
            Group {
                row {
                    HStack(spacing: 5) {
                        Text(verb).layoutPriority(1)
                        // Measured at nameRoom, so this step is taken only when that much of the name fits;
                        // laid out, it takes all that is left
                        Text(name).truncationMode(.tail)
                            .frame(minWidth: Self.nameRoom, idealWidth: Self.nameRoom, maxWidth: .infinity, alignment: .leading)
                    }
                }
                row { Text(short) }
                // Largest text: no icon, and the word shrinks rather than being cut
                Text(short).minimumScaleFactor(0.6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(line))
        }
        .font(BarLabel.textFont)
        .lineLimit(1)
        .foregroundStyle(Theme.onPrimary)
        .padding(.horizontal, 18)   // clear of the capsule's ends, where the text would touch its curve
    }

    private func row(@ViewBuilder _ text: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(BarLabel.iconFont)
            text()
        }
    }

    private var line: LocalizedStringKey {
        switch kind { case .sent: "Sent to \(name)"; case .waiting: "Waiting for \(name)" }
    }
    private var verb: LocalizedStringKey {
        switch kind { case .sent: "Sent to"; case .waiting: "Waiting for" }
    }
    private var short: LocalizedStringKey {
        switch kind { case .sent: "Sent"; case .waiting: "Waiting" }
    }
    private var symbol: String {
        switch kind { case .sent: "checkmark"; case .waiting: "clock" }
    }
}
