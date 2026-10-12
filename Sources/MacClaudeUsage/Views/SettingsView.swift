import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @AppStorage(SettingsKey.icon) private var icon: MenuIcon = .claude
    @AppStorage(SettingsKey.refreshInterval) private var interval: Int = RefreshInterval.twoMinutes.rawValue
    @AppStorage(SettingsKey.liveStatusLine) private var liveStatusLine = true
    @AppStorage(SettingsKey.showWeekly) private var showWeekly = false
    @State private var statusLineState = StatusLineInstaller.state()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 8), count: 5)

    var body: some View {
        Form {
            Section("Menu bar") {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(MenuIcon.allCases) { option in
                        Button {
                            icon = option
                        } label: {
                            Group {
                                if option == .none {
                                    Text("None").font(.caption2)
                                } else {
                                    MenuIconView(icon: option)
                                }
                            }
                            .frame(width: 40, height: 32)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(icon == option ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(icon == option ? Color.accentColor : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(option.title)
                    }
                }
                .padding(.vertical, 4)

                Toggle("Show weekly usage", isOn: $showWeekly)
                Text("Session / weekly, e.g. 13% / 5%.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Picker("Refresh every", selection: $interval) {
                    ForEach(RefreshInterval.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .onChange(of: interval) { store.restartPolling() }

                Toggle("Live updates from Claude Code", isOn: $liveStatusLine)
                    .onChange(of: liveStatusLine) { _, enabled in setLiveStatusLine(enabled) }
                Text(statusLineNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Text("Uses Claude Code's sign-in from the macOS Keychain and refreshes it the same way Claude Code does, so it keeps working without opening Claude.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if let versionText {
                        Text(versionText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Quit Claude Usage") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }

    /// `Version 1.1.0 (42)`, from the bundle's Info.plist; nil when running unbundled.
    private var versionText: String? {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    private var statusLineNote: String {
        switch statusLineState {
        case .installed:
            return "Claude Code's status line feeds usage here after every response, so the API is polled only when you're not using Claude Code."
        case .notInstalled:
            return "Off: usage comes only from the rate-limited API."
        case .occupied(let command):
            return "Your status line is already used by `\(command)`, so live updates are off. Usage comes from the API."
        }
    }

    private func setLiveStatusLine(_ enabled: Bool) {
        if enabled {
            _ = try? StatusLineInstaller.install()
        } else {
            try? StatusLineInstaller.uninstall()
        }
        statusLineState = StatusLineInstaller.state()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
