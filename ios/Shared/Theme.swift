import SwiftUI

/// Ferry's colours, from the asset catalog's colour sets (each has a light and a dark value: the spec's palette,
/// Nightdrive's violet in the dark). Views take colours only from here.
enum Theme {
    static let background = Color("Background")
    static let card = Color("Card")
    static let tile = Color("Tile")
    static let hairline = Color("Hairline")
    static let border = Color("Border")
    static let text = Color("Text")
    static let dim = Color("Dim")
    static let accent = Color("Accent")
    static let primary = Color("Primary")
    static let onPrimary = Color("OnPrimary")
    static let online = Color("Online")
    static let away = Color("Away")
}

extension Font {
    /// JetBrains Mono for content (codes, names, times), scaling with Dynamic Type like the text style it stands for.
    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .bold, .heavy, .black: "JetBrainsMono-Bold"
        case .medium, .semibold: "JetBrainsMono-Medium"
        default: "JetBrainsMono-Regular"
        }
        return .custom(name, size: monoSize(style), relativeTo: style)
    }

    /// A one-time code, large; views add `.tracking(3)`.
    static let code = mono(.title2, weight: .semibold)

    /// JetBrains Mono runs wide, so it sits a little under the system font's size for the same style.
    private static func monoSize(_ style: Font.TextStyle) -> CGFloat {
        #if os(macOS)
        // A Mac's text styles are smaller than iOS's (body 13 pt against 17)
        switch style {
        case .largeTitle: 24
        case .title: 20
        case .title2: 16
        case .title3: 14
        case .headline, .body: 12
        case .callout, .subheadline: 11
        default: 10
        }
        #else
        switch style {
        case .largeTitle: 30
        case .title: 25
        case .title2: 21
        case .title3: 18
        case .headline, .body: 15
        case .callout: 14
        case .subheadline: 13
        case .footnote: 12
        default: 11
        }
        #endif
    }
}
