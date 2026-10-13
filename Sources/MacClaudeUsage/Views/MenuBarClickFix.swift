import AppKit

/// Makes a click on the menu bar item close the open dropdown wherever on the item it lands,
/// like the system's own items do.
///
/// With the pointer pushed against the top of the screen, the press first lands in the system's
/// menu bar: MenuBarExtra closes the dropdown as for an outside click. The menu bar then
/// forwards the press to our status item, whose button toggles the dropdown on release and
/// opens it again. This drops that forwarded press when the dropdown closed with it, so the
/// button never sees the click. Clicks right on the button take another path and are left
/// alone; SwiftUI handles those fine.
@MainActor
enum MenuBarClickFix {
    /// System uptime of the last time the dropdown closed.
    private static var closedAt: TimeInterval = -.infinity
    /// Set while a dropped press waits for its release, which is dropped too.
    private static var droppedPressAt: TimeInterval?
    private static var tokens: [Any] = []

    static func install() {
        for name in [NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow, isDropdown(window) else { return }
                MainActor.assumeIsolated {
                    if name == NSWindow.didResignKeyNotification || !window.isVisible {
                        closedAt = ProcessInfo.processInfo.systemUptime
                    }
                }
            })
        }
        tokens.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            guard let window = event.window, isStatusItem(window) else { return event }
            let dropdownVisible = NSApp.windows.contains { isDropdown($0) && $0.isVisible }
            let drop: Bool
            if event.type == .leftMouseDown {
                drop = closedWithPress(pressAt: event.timestamp, closedAt: closedAt, dropdownVisible: dropdownVisible)
                droppedPressAt = drop ? event.timestamp : nil
            } else {
                drop = droppedPressAt.map { event.timestamp - $0 < 5 } ?? false
                droppedPressAt = nil
            }
            return drop ? nil : event
        } as Any)
    }

    /// The dropdown is closed, and it closed right as this press started: the press is what
    /// closed it, so it mustn't also count as a click that opens it.
    nonisolated static func closedWithPress(pressAt: TimeInterval, closedAt: TimeInterval, dropdownVisible: Bool) -> Bool {
        !dropdownVisible && closedAt >= pressAt - 0.05 && closedAt <= pressAt + 0.5
    }

    // Private AppKit/SwiftUI class names: if they ever change, this quietly does nothing.
    nonisolated private static func isStatusItem(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)) == "NSStatusBarWindow"
    }

    nonisolated private static func isDropdown(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).hasPrefix("MenuBarExtraWindow")
    }
}
