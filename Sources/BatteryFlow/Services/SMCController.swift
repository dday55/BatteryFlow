import Foundation
import IOKit

/// macOS SMC power charge/discharge control driver.
///
/// Note: This version only implements determination and state management for
/// "charge limit / operating mode", and **does not contain actual IOKit SMC writes**.
/// Writing CH0B/CH0C on Apple Silicon or BCLM on Intel requires root or a privileged helper;
/// before implementation, it always returns false and never reports a false success,
/// preventing the UI from mistakenly assuming the charge limit has taken effect.
public final class SMCController: @unchecked Sendable {
    public static let shared = SMCController()

    public enum MachineArch {
        case appleSilicon
        case intel
    }

    public let arch: MachineArch
    public private(set) var hasRootPrivilege: Bool = false
    public private(set) var isHelperInstalled: Bool = false

    /// Whether the low-level SMC write capability is available (currently always false)
    public var canWriteSMC: Bool { false }

    private init() {
        #if arch(arm64)
        self.arch = .appleSilicon
        #else
        self.arch = .intel
        #endif

        self.hasRootPrivilege = (geteuid() == 0)
        self.isHelperInstalled = FileManager.default.fileExists(
            atPath: "/Library/PrivilegedHelperTools/com.batteryflow.helper"
        )
    }

    /// Updates charge/discharge limit policy (records intent only; see `setChargingInhibited` for actual writes).
    public func updateLimit(targetLimit: Int, currentPercent: Int, mode: PowerOperationMode) {
        guard mode != .fullCharge else {
            setChargingInhibited(false, limit: 100)
            return
        }

        setChargingInhibited(currentPercent >= targetLimit, limit: targetLimit)
    }

    /// Requests write to SMC charge/discharge control registers.
    ///
    /// The actual write process is not yet implemented in this version, so it always returns false.
    /// When implemented later via a privileged helper, it should write:
    /// - Apple Silicon: `CH0B` / `CH0C` (0x01 inhibit charging, 0x00 resume charging)
    /// - Intel: `BCLM` (maximum charge limit)
    @discardableResult
    public func setChargingInhibited(_ inhibit: Bool, limit: Int) -> Bool {
        _ = inhibit
        _ = limit
        return false
    }
}
