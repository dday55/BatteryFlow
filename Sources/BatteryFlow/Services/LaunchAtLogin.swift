import Foundation
import AppKit

/// Login-item support backed by a per-user LaunchAgent.
///
/// `SMAppService.mainApp` is the modern API, but it rejects ad-hoc signed bundles and
/// apps that live outside `/Applications`. BatteryFlow ships as an ad-hoc signed bundle
/// and is often run straight from a checkout, so a LaunchAgent that simply calls
/// `open -g` is the dependable path: it works from any location and macOS lists it
/// under System Settings → General → Login Items.
@MainActor
public final class LaunchAtLogin: ObservableObject {
    public static let shared = LaunchAtLogin()

    /// True when the LaunchAgent plist is installed for the current user.
    @Published public private(set) var isEnabled: Bool = false
    /// Localized, user-facing reason for the last failed toggle, if any.
    @Published public private(set) var errorMessage: String?

    private let label = Bundle.main.bundleIdentifier ?? "com.batteryflow.app"
    private let fileManager = FileManager.default
    /// Guards against a slow async refresh overwriting a newer user action.
    private var stateRevision = 0

    private var agentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    /// `Bundle.main` is the app bundle when running from BatteryFlow.app.
    private var appURL: URL {
        Bundle.main.bundleURL.resolvingSymlinksInPath()
    }

    private var executableURL: URL {
        appURL.appendingPathComponent("Contents/MacOS/BatteryFlow")
    }

    /// The app must be launched from its bundle; a bare `./BatteryFlow` binary has no
    /// bundle to point the login item at.
    private var isBundled: Bool {
        appURL.pathExtension == "app" && fileManager.fileExists(atPath: executableURL.path)
    }

    /// macOS runs apps opened from a download in a random, ephemeral location.
    private var isTranslocated: Bool {
        appURL.path.contains("/AppTranslocation/")
    }

    private init() {
        syncInstalledAgent()
    }

    // MARK: - Public API

    public func setEnabled(_ enabled: Bool) {
        stateRevision &+= 1
        errorMessage = nil
        enabled ? enable() : disable()
    }

    /// Re-reads the plist and reports the current state. Cheap enough to call when the
    /// panel opens, so changes made in System Settings are reflected.
    public func refresh() {
        stateRevision &+= 1
        isEnabled = fileManager.fileExists(atPath: agentURL.path)
        if isEnabled {
            refreshDisabledState(revision: stateRevision)
        }
    }

    /// A user can disable a background item in System Settings; the plist stays on disk,
    /// so the toggle must also consult launchd's disabled-services database.
    private func refreshDisabledState(revision: Int) {
        let label = self.label
        let domain = self.domain
        DispatchQueue.global(qos: .utility).async {
            let output = Self.launchctlOutput(["print-disabled", domain]) ?? ""
            let disabled = output.split(separator: "\n").contains { line in
                line.contains("\"\(label)\"") && line.contains("=> disabled")
            }
            guard disabled else { return }
            Task { @MainActor [weak self] in
                guard let self, self.stateRevision == revision, self.isEnabled else { return }
                self.isEnabled = false
            }
        }
    }

    // MARK: - Enable / disable

    private func enable() {
        guard isBundled else {
            isEnabled = false
            errorMessage = L10n.t("launchAtLogin.needsBundle")
            return
        }
        guard !isTranslocated else {
            isEnabled = false
            errorMessage = L10n.t("launchAtLogin.translocated")
            return
        }

        do {
            try fileManager.createDirectory(
                at: agentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try plistData().write(to: agentURL, options: .atomic)
        } catch {
            isEnabled = false
            errorMessage = L10n.f("launchAtLogin.writeFailed", error.localizedDescription)
            return
        }

        isEnabled = true
        reloadAgentInBackground()
    }

    private func disable() {
        // Unload first: removing the plist does not unload an already bootstrapped job.
        bootoutInBackground()
        if fileManager.fileExists(atPath: agentURL.path) {
            do {
                try fileManager.removeItem(at: agentURL)
            } catch {
                errorMessage = L10n.f("launchAtLogin.removeFailed", error.localizedDescription)
            }
        }
        isEnabled = fileManager.fileExists(atPath: agentURL.path)
    }

    /// Keeps an installed login item pointing at the app's current location, so moving
    /// BatteryFlow to /Applications does not break auto-start.
    private func syncInstalledAgent() {
        guard fileManager.fileExists(atPath: agentURL.path) else {
            isEnabled = false
            return
        }
        isEnabled = true
        refreshDisabledState(revision: stateRevision)

        // Never rewrite while translocated: that would replace a valid path with a temp one.
        guard !isTranslocated, isBundled else { return }
        guard let data = try? Data(contentsOf: agentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.last != appURL.path
        else { return }

        do {
            try plistData().write(to: agentURL, options: .atomic)
            reloadAgentInBackground()
        } catch {
            // A stale path is not fatal: the toggle still reflects the installed item.
            errorMessage = L10n.f("launchAtLogin.writeFailed", error.localizedDescription)
        }
    }

    // MARK: - LaunchAgent plist

    private func plistData() throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", appURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive"
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    // MARK: - launchctl

    private var domain: String { "gui/\(getuid())" }

    /// Bootstraps the job now. `open -g` makes this a no-op when BatteryFlow is already
    /// running, so enabling the toggle never spawns a second menu bar instance.
    private func reloadAgentInBackground() {
        let domain = self.domain
        let label = self.label
        let path = agentURL.path
        DispatchQueue.global(qos: .utility).async {
            _ = Self.launchctl(["enable", "\(domain)/\(label)"])
            _ = Self.launchctl(["bootout", "\(domain)/\(label)"])
            _ = Self.launchctl(["bootstrap", domain, path])
        }
    }

    private func bootoutInBackground() {
        let domain = self.domain
        let label = self.label
        DispatchQueue.global(qos: .utility).async {
            _ = Self.launchctl(["bootout", "\(domain)/\(label)"])
        }
    }

    @discardableResult
    private nonisolated static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private nonisolated static func launchctlOutput(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain before waiting so a full pipe cannot deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
