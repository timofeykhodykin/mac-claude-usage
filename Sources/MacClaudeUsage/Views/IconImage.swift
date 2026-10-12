import AppKit
import SwiftUI

enum IconImage {
    /// SF Symbols are drawn lighter than the menu bar default so they match the text weight.
    static let symbolWeight: NSFont.Weight = .light

    /// Claude's spark mark (bundled in Contents/Resources), as a monochrome template.
    /// Falls back to an asterisk when running unbundled via `swift run`.
    static let claudeSpark: NSImage = {
        if let url = Bundle.main.url(forResource: "claude-spark", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Claude")!
    }()

    /// Template image for `icon` at `size` points, or nil for `.none`.
    static func image(for icon: MenuIcon, size: CGFloat) -> NSImage? {
        switch icon {
        case .none:
            return nil
        case .claude:
            return resized(claudeSpark, to: NSSize(width: size, height: size))
        default:
            guard let name = icon.symbolName,
                  let symbol = NSImage(systemSymbolName: name, accessibilityDescription: icon.title) else {
                return nil
            }
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: symbolWeight)
            return symbol.withSymbolConfiguration(config)
        }
    }

    private static func resized(_ image: NSImage, to size: NSSize) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        result.isTemplate = true
        return result
    }
}

/// Draws the whole menu bar item (`icon  42%`) into one template image.
///
/// MenuBarExtra ignores fonts and spacing on its label's views, so this is the only way
/// to control the text size and the gap. Being a template, it still follows the menu bar's
/// light/dark appearance.
enum MenuBarImage {
    static let iconSize: CGFloat = 14
    static let gap: CGFloat = 5
    /// SF's variable weight axis allows weights between the named ones; 450 sits between
    /// regular (400) and medium (510).
    static let fontSize: CGFloat = 12.5
    static let font: NSFont = {
        let base = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let weightAxis = 0x7767_6874 // 'wght'
        let descriptor = base.fontDescriptor.addingAttributes([.variation: [weightAxis: 450]])
        return NSFont(descriptor: descriptor, size: fontSize) ?? base
    }()
    static let height: CGFloat = 18

    static func render(icon: MenuIcon, text: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let iconImage = IconImage.image(for: icon, size: iconSize)
        let iconWidth = iconImage.map { $0.size.width } ?? 0
        let width = ceil(iconWidth + (iconImage == nil ? 0 : gap) + textSize.width)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            var x: CGFloat = 0
            if let iconImage {
                let s = iconImage.size
                iconImage.draw(in: NSRect(x: 0, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
                x = s.width + gap
            }
            // Center the text on its cap height so digits sit level with the icon.
            let baselineY = (rect.height - font.capHeight) / 2
            (text as NSString).draw(at: NSPoint(x: x, y: baselineY + font.descender), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The icon for a `MenuIcon` choice in settings.
struct MenuIconView: View {
    let icon: MenuIcon
    var size: CGFloat = 15

    var body: some View {
        if let image = IconImage.image(for: icon, size: size) {
            Image(nsImage: image)
        }
    }
}
