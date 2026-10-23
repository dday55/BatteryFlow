import Foundation

/// System power operating state.
///
/// Determined by "plugged-in status + signed measured battery power", rather than guessing bypass with "percent >= limit - 2":
/// Plugged in while battery is still discharging (insufficient adapter power, strategic discharge, charge limit calibration, etc.) falls into `.adapterAssist`,
/// rather than falsely reporting "bypass, 0 mA".
public enum PowerState: String, Sendable, CaseIterable {
    /// Unplugged, battery solely powers the system.
    case batteryOnly
    /// Plugged in, and actively charging the battery.
    case charging
    /// Plugged in, charging stopped, with battery current near zero (true bypass / direct AC supply).
    case chargeStopped
    /// Plugged in, but battery is discharging (insufficient adapter supply or system strategic discharge).
    case adapterAssist
    /// Plugged in, charge limiter is reducing battery level to target limit (active battery discharge, not adapter shortage).
    case limitDischarge
}

/// Source of real-time telemetry data.
public enum TelemetrySource: String, Sendable {
    case smc
    case systemSnapshot
    case unavailable
}

/// Snapshot of system power operating state and power flow distribution.
/// Telemetry fields are Optional: unreadable values are `nil` and displayed as "—".
public struct PowerSnapshot: Sendable {
    public var batteryPercent: Int = 100
    public var isPluggedIn: Bool = false
    /// Whether the system reports charging (IOPS flag; may differ from measured current).
    public var isCharging: Bool = false
    public var powerState: PowerState = .batteryOnly

    public var voltageVolts: Double?
    /// Instantaneous battery current (mA, positive = charging, negative = discharging).
    public var batteryCurrentMa: Double?
    public var currentSource: TelemetrySource = .unavailable
    public var powerSource: TelemetrySource = .unavailable
    public var temperatureCelsius: Double?
    public var cycleCount: Int?
    public var healthPercent: Double?
    public var currentCapacityMah: Int?
    public var maxCapacityMah: Int?
    public var designCapacityMah: Int?

    public var systemLoadWatts: Double?
    public var adapterInputWatts: Double?
    public var adapterInputCurrentMa: Double?
    public var adapterInputVoltageVolts: Double?
    public var batteryDischargeWatts: Double = 0

    public var adapterWatts: Double = 0
    public var adapterName: String = L10n.t("adapter.notConnected")

    public var sourceWatts: Double = 0
    public var batteryStorageWatts: Double = 0
    public var systemDirectWatts: Double = 0

    public var chargeLimit: Int = 80
    public var isBypassActive: Bool { powerState == .chargeStopped }
}

// MARK: - Equatable (deduplication with tolerance to avoid unnecessary UI redraws)

extension PowerSnapshot: Equatable {
    public static func == (lhs: PowerSnapshot, rhs: PowerSnapshot) -> Bool {
        lhs.batteryPercent == rhs.batteryPercent
            && lhs.isPluggedIn == rhs.isPluggedIn
            && lhs.isCharging == rhs.isCharging
            && lhs.powerState == rhs.powerState
            && lhs.currentSource == rhs.currentSource
            && lhs.powerSource == rhs.powerSource
            && lhs.chargeLimit == rhs.chargeLimit
            && lhs.adapterName == rhs.adapterName
            && approx(lhs.adapterWatts, rhs.adapterWatts, 0.1)
            && approx(lhs.voltageVolts, rhs.voltageVolts, 0.002)
            && approx(lhs.batteryCurrentMa, rhs.batteryCurrentMa, 5)
            && approx(lhs.temperatureCelsius, rhs.temperatureCelsius, 0.05)
            && lhs.cycleCount == rhs.cycleCount
            && approx(lhs.healthPercent, rhs.healthPercent, 0.1)
            && lhs.currentCapacityMah == rhs.currentCapacityMah
            && lhs.maxCapacityMah == rhs.maxCapacityMah
            && lhs.designCapacityMah == rhs.designCapacityMah
            && approx(lhs.systemLoadWatts, rhs.systemLoadWatts, 0.02)
            && approx(lhs.adapterInputWatts, rhs.adapterInputWatts, 0.02)
            && approx(lhs.adapterInputCurrentMa, rhs.adapterInputCurrentMa, 5)
            && approx(lhs.adapterInputVoltageVolts, rhs.adapterInputVoltageVolts, 0.02)
            && approx(lhs.batteryDischargeWatts, rhs.batteryDischargeWatts, 0.02)
            && approx(lhs.sourceWatts, rhs.sourceWatts, 0.02)
            && approx(lhs.batteryStorageWatts, rhs.batteryStorageWatts, 0.02)
            && approx(lhs.systemDirectWatts, rhs.systemDirectWatts, 0.02)
    }
}

private func approx(_ a: Double?, _ b: Double?, _ eps: Double) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (lhs?, rhs?): return abs(lhs - rhs) <= eps
    default: return false
    }
}

private func approx(_ a: Double, _ b: Double, _ eps: Double) -> Bool {
    abs(a - b) <= eps
}

public enum PowerOperationMode: String, CaseIterable, Identifiable {
    case smartBypass = "智能旁路"
    case chargeToLimit = "充至上限"
    case fullCharge = "充满模式"

    public var id: String { rawValue }

    /// Display name for UI (localized; persistence retains rawValue for compatibility)
    public var displayName: String {
        switch self {
        case .smartBypass: return L10n.t("mode.smartBypass")
        case .chargeToLimit: return L10n.t("mode.chargeToLimit")
        case .fullCharge: return L10n.t("mode.fullCharge")
        }
    }

    public var description: String {
        switch self {
        case .smartBypass:
            return L10n.t("mode.smartBypass.desc")
        case .chargeToLimit:
            return L10n.t("mode.chargeToLimit.desc")
        case .fullCharge:
            return L10n.t("mode.fullCharge.desc")
        }
    }
}
