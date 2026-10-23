import Foundation
import SwiftUI
import IOKit.ps
import IOKit
import AppKit

@MainActor
public final class PowerManager: ObservableObject {
    public static let shared = PowerManager()

    @Published public private(set) var snapshot: PowerSnapshot = PowerSnapshot()
    /// Charge control state (whether helper is installed, whether active)
    @Published private(set) var chargeControlState: ChargeControlState = .unknown
    /// Whether helper + sudoers is configured (cached to avoid repeated sudo spawns in view body)
    @Published private(set) var helperConfigured: Bool = false
    @Published public var chargeLimit: Int {
        didSet {
            UserDefaults.standard.set(chargeLimit, forKey: "chargeLimit")
            enforceChargeLimit(force: true)
            // Limit change affects bypass determination; trigger an immediate resample
            refreshSnapshot()
        }
    }
    @Published public var operationMode: PowerOperationMode = .smartBypass {
        didSet {
            UserDefaults.standard.set(operationMode.rawValue, forKey: "operationMode")
            enforceChargeLimit(force: true)
        }
    }

    /// Low-priority background sampling queue: IOKit reads do not block the main thread
    private let samplerQueue = DispatchQueue(label: "com.batteryflow.sampler", qos: .utility)
    private var isSampling = false
    private var needsResample = false

    private var runLoopSource: CFRunLoopSource?
    /// Continuous 1s snapshot refresh (paused during lock screen / sleep)
    private var fastTimer: Timer?
    /// IOPS power event debounce
    private var eventWorkItem: DispatchWorkItem?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []

    private var isPanelVisible = false
    private var isSystemAwake = true
    private var lastPolicySignature = ""
    private var lastPolicyAppliedAt = Date.distantPast

    private init() {
        let savedLimit = UserDefaults.standard.integer(forKey: "chargeLimit")
        self.chargeLimit = savedLimit > 0 ? savedLimit : 80

        if let savedModeStr = UserDefaults.standard.string(forKey: "operationMode"),
           let savedMode = PowerOperationMode(rawValue: savedModeStr) {
            self.operationMode = savedMode
        }

        refreshSnapshot()
        setupIOKitNotification()
        setupSystemObservers()

        // Continuous 1s sampling: SMC current/voltage/power/temperature are second-level data,
        // no longer relying on MenuBarExtra's unreliable onAppear/onDisappear for sampling rate.
        startFastTimer()
    }

    // Note: PowerManager is an application-lifetime singleton (init is private).
    // Timers, notification observers, and RunLoopSource share process lifetime without deinit cleanup;
    // if refactored to disposable instances later, timer cancellation/observer removal logic must be added.

    // MARK: - Refresh Scheduling

    /// Requests a snapshot refresh. Sampling executes on a background serial queue; main actor publishes.
    public func refreshSnapshot() {
        if isSampling {
            needsResample = true
            return
        }
        isSampling = true
        let limit = chargeLimit
        let limitActive: Bool = {
            if case .applied = chargeControlState { return true }
            return false
        }()
        samplerQueue.async { [weak self] in
            let newSnapshot = PowerSampler.sample(chargeLimit: limit, isChargeLimitActive: limitActive)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSampling = false
                self.publish(newSnapshot)
                if self.needsResample {
                    self.needsResample = false
                    self.refreshSnapshot()
                }
            }
        }
    }

    private func publish(_ newSnapshot: PowerSnapshot) {
        // Deduplicate with tolerance: skip SwiftUI recalculation and animations if data is unchanged
        guard newSnapshot != snapshot else { return }
        snapshot = newSnapshot
        enforceChargeLimit()
    }

    /// Called on menu bar panel visibility changes: triggers immediate snapshot upon opening.
    /// Sampling runs continuously every 1s regardless of panel state to prevent stale data upon reopen.
    public func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        if visible {
            refreshSnapshot()
        }
    }

    // MARK: - Timers

    private func startFastTimer() {
        guard fastTimer == nil, isSystemAwake else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        fastTimer = timer
    }

    private func stopFastTimer() {
        fastTimer?.invalidate()
        fastTimer = nil
    }

    // MARK: - IOKit Power Events

    private func setupIOKitNotification() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ info in
            guard let info = info else { return }
            let manager = Unmanaged<PowerManager>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                manager.schedulePowerSourceRefresh()
            }
        }, context).takeRetainedValue()

        self.runLoopSource = source
        // Use commonModes: receive power events even in eventTracking modes (menu tracking, drag, etc.)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// IOPS plug/unplug or state transitions often trigger multiple rapid callbacks; debounce into a single sample.
    private func schedulePowerSourceRefresh() {
        eventWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
        eventWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Screen Lock / Sleep

    private func setupSystemObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemSleep() }
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemSleep() }
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemWake() }
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemWake() }
        })

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.append(distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemSleep() }
        })
        distributedObservers.append(distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemWake() }
        })

        // The app resigns active when panel closes (click outside); acts as fallback beyond onDisappear.
        localObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setPanelVisible(false) }
        })
    }

    private func handleSystemSleep() {
        guard isSystemAwake else { return }
        isSystemAwake = false
        stopFastTimer()
    }

    private func handleSystemWake() {
        guard !isSystemAwake else { return }
        isSystemAwake = true
        lastPolicySignature = ""
        startFastTimer()
        refreshSnapshot()
    }

    // MARK: - Charge Limit Control

    /// Invokes helper only when policy actually changes to avoid forking sudo every second.
    private func enforceChargeLimit(force: Bool = false) {
        // After installing helper in terminal, next sample retries automatically without restarting the app.
        let force = force || (chargeControlState == .helperMissing && ChargeLimiter.isHelperInstalled)

        let limit = chargeLimit
        let percent = snapshot.batteryPercent
        let plugged = snapshot.isPluggedIn
        let shouldInhibit = operationMode != .fullCharge && plugged && percent >= limit

        let signature = "\(limit)|\(operationMode.rawValue)|\(plugged)|\(shouldInhibit)"
        let now = Date()
        if !force, signature == lastPolicySignature,
           now.timeIntervalSince(lastPolicyAppliedAt) < 60 {
            return
        }
        if !force, !shouldInhibit, chargeControlState == .reset {
            return
        }

        lastPolicySignature = signature
        lastPolicyAppliedAt = now
        chargeControlState = ChargeLimiter.apply(
            limit: limit,
            mode: operationMode,
            batteryPercent: percent,
            isPluggedIn: plugged
        )
    }

    /// Installs charge limiter helper via administrator authorization prompt.
    public func installChargeHelper() {
        chargeControlState = .installing
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ChargeLimiter.installHelper()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if result.ok {
                    self.helperConfigured = true
                    self.chargeControlState = .unknown
                    self.enforceChargeLimit(force: true)
                } else {
                    self.chargeControlState = .failed(result.message)
                }
            }
        }
    }

    /// Manually retries current charge limit policy (used when helper is installed but write failed).
    public func retryChargeLimit() {
        lastPolicySignature = ""
        enforceChargeLimit(force: true)
    }

    private var didAttemptAutoInstall = false

    private func autoInstallHelperIfNeeded() {
        guard !didAttemptAutoInstall else { return }
        didAttemptAutoInstall = true
        guard !helperConfigured else { return }
        guard ProcessInfo.processInfo.environment["BATTERYFLOW_SKIP_HELPER_PROMPT"] != "1" else { return }
        NSLog("[BatteryFlow] helper not configured, prompting")
        installChargeHelper()
    }
}

// MARK: - Background Sampler

/// Performs all IOKit reads on a background queue and outputs a pure value-type snapshot.
enum PowerSampler {
    static func sample(chargeLimit: Int, isChargeLimitActive: Bool = false) -> PowerSnapshot {
        var snapshot = PowerSnapshot()
        snapshot.chargeLimit = chargeLimit

        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
           let firstSource = list.first,
           let desc = IOPSGetPowerSourceDescription(info, firstSource)?.takeUnretainedValue() as? [String: Any] {
            snapshot.batteryPercent = desc[kIOPSCurrentCapacityKey] as? Int ?? snapshot.batteryPercent
            snapshot.isPluggedIn = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            snapshot.isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
        }

        if let adapterDict = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            snapshot.adapterWatts = Double(adapterDict[kIOPSPowerAdapterWattsKey] as? Int ?? 0)
            snapshot.adapterName = adapterDict["Name"] as? String ?? L10n.f("adapter.fallbackName", Int(snapshot.adapterWatts))
        } else {
            snapshot.adapterWatts = 0
            snapshot.adapterName = snapshot.isPluggedIn ? L10n.t("adapter.externalPower") : L10n.t("adapter.notConnected")
        }

        readBatteryTelemetry(into: &snapshot, smcReading: SMCReader.readBattery())
        calculatePowerFlows(&snapshot, isChargeLimitActive: isChargeLimitActive)

        return snapshot
    }

    private static func readBatteryTelemetry(
        into snapshot: inout PowerSnapshot,
        smcReading: SMCBatteryReading
    ) {
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }

            if let mv = intValue(service, "Voltage"), mv > 0 {
                snapshot.voltageVolts = Double(mv) / 1000.0
            }

            if let currentMa = intValue(service, "InstantAmperage") ?? intValue(service, "Amperage") {
                snapshot.batteryCurrentMa = Double(currentMa)
                snapshot.currentSource = .systemSnapshot
            }

            if let tempRaw = intValue(service, "Temperature") {
                snapshot.temperatureCelsius = max(0.0, (Double(tempRaw) / 10.0) - 273.15)
            }

            snapshot.cycleCount = intValue(service, "CycleCount") ?? snapshot.cycleCount
            snapshot.currentCapacityMah = intValue(service, "AppleRawCurrentCapacity") ?? snapshot.currentCapacityMah
            snapshot.maxCapacityMah = intValue(service, "AppleRawMaxCapacity") ?? snapshot.maxCapacityMah
            snapshot.designCapacityMah = intValue(service, "DesignCapacity") ?? snapshot.designCapacityMah

            if let telemetry = dictionaryValue(service, "PowerTelemetryData") {
                if let systemLoadMw = telemetry["SystemLoad"] as? Int, systemLoadMw > 0 {
                    snapshot.systemLoadWatts = Double(systemLoadMw) / 1000.0
                    snapshot.powerSource = .systemSnapshot
                }

                if snapshot.isPluggedIn {
                    if let powerInMw = telemetry["SystemPowerIn"] as? Int, powerInMw > 0 {
                        snapshot.adapterInputWatts = Double(powerInMw) / 1000.0
                        snapshot.powerSource = .systemSnapshot
                    }
                    if let voltageInMv = telemetry["SystemVoltageIn"] as? Int, voltageInMv > 0 {
                        snapshot.adapterInputVoltageVolts = Double(voltageInMv) / 1000.0
                    }
                    if let currentInMa = telemetry["SystemCurrentIn"] as? Int {
                        snapshot.adapterInputCurrentMa = Double(currentInMa)
                    }
                }
            }
        }

        // SMC fast path: prioritize second-level gas gauge readings; keep system snapshot values if keys are absent or failed.
        // Note: B0AC and InstantAmperage share the same sign convention (positive for charging, negative for discharging).
        if smcReading.hasAnyValue {
            if let current = smcReading.currentMa {
                snapshot.batteryCurrentMa = current
                snapshot.currentSource = .smc
            }
            if let voltage = smcReading.voltageVolts {
                snapshot.voltageVolts = voltage
            }
            // Power/temperature also from SMC: adapter input PDTR, input voltage VD0R, battery temperature TB0T,
            // all refreshed at ~1s interval, avoiding minute-level caching in PowerTelemetryData.
            if snapshot.isPluggedIn, let adapterPower = smcReading.adapterInputWatts {
                snapshot.adapterInputWatts = adapterPower
                snapshot.powerSource = .smc
                if let adapterVoltage = smcReading.adapterInputVoltageVolts, adapterVoltage > 0 {
                    snapshot.adapterInputVoltageVolts = adapterVoltage
                    snapshot.adapterInputCurrentMa = adapterPower / adapterVoltage * 1000.0
                }
            }
            if let temperature = smcReading.temperatureCelsius {
                snapshot.temperatureCelsius = temperature
            }
            if let currentCapacity = smcReading.currentCapacityMah {
                snapshot.currentCapacityMah = currentCapacity
            }
            if let maxCapacity = smcReading.maxCapacityMah {
                snapshot.maxCapacityMah = maxCapacity
            }
            if let cycles = smcReading.cycleCount {
                snapshot.cycleCount = cycles
            }
        }

        // Capacity might be overwritten during SMC stage; recalculate health percentage here
        if let maxCapacity = snapshot.maxCapacityMah,
           let designCapacity = snapshot.designCapacityMah,
           maxCapacity > 0, designCapacity > 0 {
            snapshot.healthPercent = min(100.0, Double(maxCapacity) / Double(designCapacity) * 100.0)
        }
    }

    private static func calculatePowerFlows(
        _ snapshot: inout PowerSnapshot,
        isChargeLimitActive: Bool
    ) {
        let batteryWatts: Double? = {
            guard let voltage = snapshot.voltageVolts,
                  let currentMa = snapshot.batteryCurrentMa else { return nil }
            return voltage * currentMa / 1000.0
        }()

        let chargeWatts = max(0.0, batteryWatts ?? 0.0)
        let dischargeWatts = abs(min(0.0, batteryWatts ?? 0.0))
        snapshot.batteryDischargeWatts = dischargeWatts

        let systemLoadWatts = snapshot.systemLoadWatts ?? 0.0
        let adapterInputWatts = snapshot.adapterInputWatts ?? 0.0

        // State determination: based on measured current/power, avoiding guessing bypass with "percent >= limit - 2"
        if !snapshot.isPluggedIn {
            snapshot.powerState = .batteryOnly
        } else if let batteryWatts, batteryWatts > 0.5 {
            snapshot.powerState = .charging
        } else if let batteryWatts, batteryWatts < -0.5 {
            let isLimitDischarge = isChargeLimitActive
                && snapshot.batteryPercent >= snapshot.chargeLimit
            snapshot.powerState = isLimitDischarge ? .limitDischarge : .adapterAssist
        } else {
            snapshot.powerState = .chargeStopped
        }

        // SMC PDTR provides second-level adapter input power; derive system load from it and battery power,
        // avoiding minute-level SystemLoad (and one-beat lag from PSTR).
        let smcRealtimePower = snapshot.powerSource == .smc && snapshot.isPluggedIn && adapterInputWatts > 0
        let derivedSystemWatts: Double? = smcRealtimePower
            ? {
                switch snapshot.powerState {
                case .charging:
                    return max(0.0, adapterInputWatts - chargeWatts)
                case .chargeStopped:
                    return adapterInputWatts
                case .adapterAssist, .limitDischarge:
                    return adapterInputWatts + dischargeWatts
                case .batteryOnly:
                    return nil
                }
            }()
            : nil
        if let derivedSystemWatts {
            snapshot.systemLoadWatts = derivedSystemWatts
        }
        // Battery only: battery power itself represents system load, routed through second-level SMC telemetry
        if snapshot.powerState == .batteryOnly,
           snapshot.currentSource == .smc,
           dischargeWatts > 0.5 {
            snapshot.systemLoadWatts = dischargeWatts
            snapshot.powerSource = .smc
        }

        switch snapshot.powerState {
        case .charging:
            snapshot.batteryStorageWatts = chargeWatts
            snapshot.systemDirectWatts = derivedSystemWatts
                ?? (systemLoadWatts > 0 ? systemLoadWatts : max(0.0, adapterInputWatts - chargeWatts))
            snapshot.sourceWatts = snapshot.batteryStorageWatts + snapshot.systemDirectWatts

        case .chargeStopped:
            snapshot.batteryStorageWatts = 0
            snapshot.systemDirectWatts = derivedSystemWatts
                ?? (systemLoadWatts > 0 ? systemLoadWatts : adapterInputWatts)
            snapshot.sourceWatts = snapshot.systemDirectWatts

        case .adapterAssist, .limitDischarge:
            // Plugged in while battery discharging: battery counts as negative storage power, UI displays "Discharging"
            snapshot.batteryStorageWatts = -dischargeWatts
            snapshot.systemDirectWatts = derivedSystemWatts ?? (systemLoadWatts > 0
                ? systemLoadWatts
                : adapterInputWatts + dischargeWatts)
            snapshot.sourceWatts = snapshot.systemDirectWatts

        case .batteryOnly:
            snapshot.batteryStorageWatts = 0
            snapshot.systemDirectWatts = dischargeWatts > 0.5
                ? dischargeWatts
                : (systemLoadWatts > 0 ? systemLoadWatts : 0)
            snapshot.sourceWatts = snapshot.systemDirectWatts
        }
    }

    private static func intValue(_ service: io_service_t, _ key: String) -> Int? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return unmanaged.takeRetainedValue() as? Int
    }

    private static func dictionaryValue(_ service: io_service_t, _ key: String) -> [String: Any]? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return unmanaged.takeRetainedValue() as? [String: Any]
    }
}
