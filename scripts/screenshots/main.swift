import AppKit
import SwiftUI

// Renders the README screenshots from the real views, offscreen, in light and dark
// appearance, with sample data. Run via scripts/screenshots.sh.
_ = NSApplication.shared
let out = CommandLine.arguments[1]

func snapshot<V: View>(_ view: V, dark: Bool, file: String) {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(file)"))
}

let now = Date()
let sample = UsageSnapshot(
    session: UsageWindow(utilization: 37, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
    weekly: UsageWindow(utilization: 64, resetsAt: Calendar.current.date(byAdding: .day, value: 3, to: now)),
    fetchedAt: now.addingTimeInterval(-42), source: .api)

@MainActor func dropdown() -> some View {
    MenuContentView(store: UsageStore(previewSnapshot: sample, plan: "pro"))
        .background(Color(nsColor: .windowBackgroundColor))
}

@MainActor func settings() -> some View {
    SettingsView(store: UsageStore(previewSnapshot: sample, plan: "pro"))
        .background(Color(nsColor: .windowBackgroundColor))
}

/// The menu bar item for each icon option, as the system would tint the template image.
func menuBarStrip(dark: Bool, file: String) {
    let items = MenuIcon.allCases.filter { $0 != .none }
    let cell = NSSize(width: 74, height: 24)
    let size = NSSize(width: cell.width * CGFloat(items.count) + 12, height: cell.height)
    let fg: NSColor = dark ? .white : .black
    let image = NSImage(size: size, flipped: false) { rect in
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        rect.fill()
        for (i, icon) in items.enumerated() {
            let label = MenuBarImage.render(icon: icon, text: "37%")
            let tinted = NSImage(size: label.size, flipped: false) { r in
                label.draw(in: r); fg.set(); r.fill(using: .sourceAtop); return true
            }
            tinted.draw(at: NSPoint(x: 12 + CGFloat(i) * cell.width, y: (cell.height - label.size.height) / 2),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(file)"))
}

MainActor.assumeIsolated {
    menuBarStrip(dark: false, file: "menubar-light.png")
    menuBarStrip(dark: true, file: "menubar-dark.png")
    snapshot(dropdown(), dark: false, file: "dropdown-light.png")
    snapshot(dropdown(), dark: true, file: "dropdown-dark.png")
    snapshot(settings(), dark: false, file: "settings-light.png")
    snapshot(settings(), dark: true, file: "settings-dark.png")
}
print("ok")
