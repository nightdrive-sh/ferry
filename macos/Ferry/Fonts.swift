import CoreText
import Foundation

/// JetBrains Mono, bundled as the iOS app's is. A Mac app has no UIAppFonts, so the fonts are registered for the
/// process at launch, before any view asks for them.
enum Fonts {
    static func register() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }
}
