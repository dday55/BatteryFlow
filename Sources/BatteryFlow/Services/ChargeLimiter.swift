import Foundation

enum ChargeControlState: Equatable {
    case unknown
    case installing
    case helperMissing
    case applied(Int)
    case reset
    case failed(String)
}

/// New charging control channel for macOS 15.8+/26+.
///
/// Legacy SMC keys `CH0B`/`CH0C`/`CHTE` have been removed by Apple; newer firmware uses
/// `bfF0` (mode), `bfD0` (upper limit), and `bfE0` (lower limit), requiring root to write.
/// Therefore, the App writes via a least-privilege helper `/usr/local/libexec/batteryflow-smc`,
/// which only accepts `golden-gate <upper> <lower>` and `reset` commands.
enum ChargeLimiter {
    static let helperPath = "/usr/local/libexec/batteryflow-smc"
    private static let sudoPath = "/usr/bin/sudo"
    private static let osascriptPath = "/usr/bin/osascript"

    static var isHelperInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperPath)
    }

    /// Whether helper is installed and sudoers authorization is valid.
    static var isConfigured: Bool {
        guard isHelperInstalled else { return false }
        return run(arguments: ["status"], useSudo: true).ok
    }

    /// Applies charge limit or resumes normal charging according to current policy.
    static func apply(
        limit: Int,
        mode: PowerOperationMode,
        batteryPercent: Int,
        isPluggedIn: Bool
    ) -> ChargeControlState {
        guard isHelperInstalled else { return .helperMissing }

        let shouldInhibit = mode != .fullCharge && isPluggedIn && batteryPercent >= limit
        if shouldInhibit {
            let upper = min(100, max(2, limit))
            let lower = max(2, upper - 2)
            let result = run(arguments: ["golden-gate", "\(upper)", "\(lower)"], useSudo: true)
            return result.ok ? .applied(upper) : .failed(result.message)
        } else {
            let result = run(arguments: ["reset"], useSudo: true)
            return result.ok ? .reset : .failed(result.message)
        }
    }

    /// Fully built-in helper installation: copies helper from App Bundle and writes sudoers,
    /// executed via macOS administrator authorization dialog; does not rely on external scripts.
    static func installHelper() -> (ok: Bool, message: String) {
        guard let helperSource = Bundle.main.url(
            forResource: "batteryflow-smc",
            withExtension: nil
        )?.path else {
            NSLog("[BatteryFlow] helper resource missing in bundle: %@", Bundle.main.bundlePath)
            return (false, L10n.t("error.helperResourceMissing"))
        }
        NSLog("[BatteryFlow] installing helper from %@", helperSource)

        let quotedSource = shellQuote(helperSource)
        let shell = """
        set -e
        mkdir -p /usr/local/libexec
        install -o root -g wheel -m 0755 \(quotedSource) /usr/local/libexec/batteryflow-smc
        tmp=$(mktemp)
        printf '%s\n' 'ALL ALL = NOPASSWD: /usr/local/libexec/batteryflow-smc status, /usr/local/libexec/batteryflow-smc reset, /usr/local/libexec/batteryflow-smc golden-gate *' > "$tmp"
        chown root:wheel "$tmp"
        chmod 0440 "$tmp"
        /usr/sbin/visudo -cf "$tmp" >/dev/null
        mv "$tmp" /etc/sudoers.d/batteryflow
        chown root:wheel /etc/sudoers.d/batteryflow
        chmod 0440 /etc/sudoers.d/batteryflow
        """

        // Pass script via base64 to avoid quoting and newline escaping issues in AppleScript / shell.
        let base64 = Data(shell.utf8).base64EncodedString()
        let appleScript = "do shell script \"echo \(base64) | /usr/bin/base64 -D | /bin/bash\" with administrator privileges"

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = ["-e", appleScript]
        process.environment = environment
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return (false, L10n.f("error.installStartFailed", error.localizedDescription))
        }
        process.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 0 {
            NSLog("[BatteryFlow] helper installation succeeded")
            return (true, "")
        }
        if errorText.contains("-128") || errorText.localizedCaseInsensitiveContains("canceled") {
            return (false, L10n.t("error.installCanceled"))
        }
        NSLog("[BatteryFlow] helper installation failed: %@", errorText)
        return (false, errorText.isEmpty ? L10n.f("error.installFailedCode", process.terminationStatus) : errorText)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(
        arguments: [String],
        useSudo: Bool
    ) -> (ok: Bool, message: String) {
        let process = Process()
        if useSudo {
            process.executableURL = URL(fileURLWithPath: sudoPath)
            process.arguments = ["-n", helperPath] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = arguments
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return (false, L10n.f("error.helperStartFailed", error.localizedDescription))
        }
        process.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch process.terminationStatus {
        case 0:
            return (true, "")
        case 1 where errorText.localizedCaseInsensitiveContains("password is required"):
            return (false, L10n.t("error.helperNeedsInstall"))
        case 3:
            return (false, L10n.t("error.helperPermission"))
        case 4:
            return (false, L10n.f("error.smcWriteFailed", errorText.isEmpty ? L10n.t("error.unknown") : errorText))
        default:
            return (false, errorText.isEmpty ? L10n.f("error.helperExitCode", process.terminationStatus) : errorText)
        }
    }
}
