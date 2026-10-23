import SwiftUI
import AppKit

public struct MenuBarView: View {
    @ObservedObject var power = PowerManager.shared
    @State private var showHardwareDetails: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            header
            DualBranchSankeyView(
                sourceWatts: power.snapshot.sourceWatts,
                batteryWatts: power.snapshot.batteryStorageWatts,
                systemWatts: power.snapshot.systemDirectWatts,
                powerState: power.snapshot.powerState,
                isPluggedIn: power.snapshot.isPluggedIn
            )
            metrics
            controls
            details
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            power.setPanelVisible(true)
        }
        .onDisappear {
            power.setPanelVisible(false)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 4)
                    .frame(width: 44, height: 44)

                Circle()
                    .trim(from: 0.0, to: CGFloat(power.snapshot.batteryPercent) / 100.0)
                    .stroke(
                        batteryColor(for: power.snapshot.batteryPercent),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 44, height: 44)
                    .animation(ValueAnimation.curve, value: power.snapshot.batteryPercent)

                RollingNumberText(
                    value: Double(power.snapshot.batteryPercent),
                    format: "%.0f",
                    suffix: "%",
                    unitSpacing: 0.5
                )
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .animation(ValueAnimation.curve, value: power.snapshot.batteryPercent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("BatteryFlow")
                        .font(.system(size: 14, weight: .bold))

                    if power.snapshot.isBypassActive {
                        Text("BYPASS")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(.green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(3)
                    }
                }

                Text(statusDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer()

            // Target limit badge (interactive value; not eased to keep slider responsive)
            VStack(alignment: .trailing, spacing: 2) {
                Text(L10n.t("header.protectLimit"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("\(power.chargeLimit)%")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(6)
        }
        .padding(.top, 2)
    }

    private var metrics: some View {
        HStack(spacing: 8) {
            MetricTile(
                title: L10n.t("metric.temperature"),
                value: power.snapshot.temperatureCelsius,
                format: "%.1f",
                unit: "°C",
                icon: "thermometer.medium",
                tint: temperatureColor(for: power.snapshot.temperatureCelsius)
            )
            MetricTile(
                title: L10n.t("metric.health"),
                value: power.snapshot.healthPercent,
                format: "%.0f",
                unit: "%",
                icon: "heart.fill",
                tint: .pink
            )
            MetricTile(
                title: L10n.t("metric.cycles"),
                value: power.snapshot.cycleCount.map(Double.init),
                format: "%.0f",
                unit: L10n.t("unit.cycles"),
                icon: "arrow.2.circlepath",
                tint: .teal
            )
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.t("controls.limitSection"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(power.chargeLimit)%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.accentColor)
            }

            Slider(value: Binding(
                get: { Double(power.chargeLimit) },
                set: { power.chargeLimit = Int($0) }
            ), in: 60...100, step: 5)
            .accentColor(.accentColor)

            Picker("", selection: $power.operationMode) {
                ForEach(PowerOperationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            chargeControlRow
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var chargeControlRow: some View {
        switch power.chargeControlState {
        case .unknown, .applied, .reset:
            // Hidden when charge limiting is operating normally to keep controls uncluttered
            EmptyView()

        case .installing:
            chargeStatusLine(
                icon: "clock.arrow.circlepath",
                text: L10n.t("controls.helperInstalling"),
                color: .secondary
            )

        case .helperMissing:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                Text(L10n.t("controls.helperNeedsInstall"))
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                Spacer()
                Button(L10n.t("controls.install")) {
                    power.installChargeHelper()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
            }

        case .failed(let message):
            if power.helperConfigured {
                // Suppress persistent failure banner if already authorized to avoid clutter
                EmptyView()
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                    Spacer()
                    Button(L10n.t("controls.install")) {
                        power.installChargeHelper()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold))
                }
            }
        }
    }

    private func chargeStatusLine(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(color)
            Spacer()
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showHardwareDetails.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showHardwareDetails ? 90 : 0))
                        .frame(width: 10)

                    Text(L10n.t("details.title"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary.opacity(0.85))

                    Spacer()

                    HStack(spacing: 4) {
                        Circle()
                            .fill(telemetryIndicatorColor)
                            .frame(width: 5, height: 5)
                        Text(telemetryIndicatorText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .help(telemetryIndicatorHelp)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if showHardwareDetails {
                hardwareDetailRows
                    .padding(.leading, 16)
                    .padding(.top, 8)
                    .padding(.trailing, 1)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 1)
                            .padding(.leading, 5)
                            .padding(.vertical, 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var hardwareDetailRows: some View {
        VStack(spacing: 8) {
            DetailRow(label: L10n.t("details.adapter"), value: adapterText)
            AnimatedDetailRow(label: L10n.t("details.voltage"), value: power.snapshot.voltageVolts, format: "%.3f", suffix: " V")
            AnimatedDetailRow(label: L10n.t("details.systemLoad"), value: power.snapshot.systemLoadWatts, format: "%.2f", suffix: " W")

            if let parts = adapterInputParts {
                DetailValueRow(label: L10n.t("details.adapterInput"), parts: parts)
            } else {
                DetailRow(label: L10n.t("details.adapterInput"), value: L10n.t("details.adapterInputUnavailable"))
            }

            if let parts = batteryCurrentParts {
                DetailValueRow(label: L10n.t("details.batteryCurrent"), parts: parts)
            } else {
                DetailRow(label: L10n.t("details.batteryCurrent"), value: "—")
            }


            if let parts = batteryPowerParts {
                DetailValueRow(label: L10n.t("details.batteryPower"), parts: parts)
            } else {
                DetailRow(label: L10n.t("details.batteryPower"), value: "—")
            }

            if let parts = capacityParts {
                DetailValueRow(label: L10n.t("details.capacity"), parts: parts)
            } else {
                DetailRow(label: L10n.t("details.capacity"), value: "—")
            }

            DetailRow(label: L10n.t("details.designCapacity"), value: designCapacityText)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(L10n.t("footer.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
        }
        .padding(.bottom, 2)
    }

    private var statusDescription: String {
        switch power.snapshot.powerState {
        case .batteryOnly:
            return L10n.t("status.batteryOnly")
        case .charging:
            return L10n.t("status.charging")
        case .chargeStopped:
            return L10n.t("status.chargeStopped")
        case .adapterAssist:
            return L10n.t("status.adapterAssist")
        case .limitDischarge:
            return L10n.t("status.limitDischarge")
        }
    }

    /// True second-level real-time only when both current and power originate from SMC
    private var isSMCRealtime: Bool {
        power.snapshot.currentSource == .smc && power.snapshot.powerSource == .smc
    }

    private var hasAnyTelemetry: Bool {
        power.snapshot.currentSource != .unavailable || power.snapshot.powerSource != .unavailable
    }

    private var telemetryIndicatorText: String {
        if isSMCRealtime { return L10n.t("telemetry.smc") }
        return hasAnyTelemetry ? L10n.t("telemetry.snapshot") : L10n.t("telemetry.none")
    }

    private var telemetryIndicatorColor: Color {
        if isSMCRealtime { return .green }
        return hasAnyTelemetry ? .orange : .secondary
    }

    private var telemetryIndicatorHelp: String {
        if isSMCRealtime {
            return L10n.t("telemetry.help.smc")
        }
        if hasAnyTelemetry {
            return L10n.t("telemetry.help.snapshot")
        }
        return L10n.t("telemetry.help.none")
    }

    private var adapterText: String {
        guard power.snapshot.isPluggedIn else { return L10n.t("adapter.notConnected") }
        let watts = power.snapshot.adapterWatts
        return watts > 0 ? L10n.f("adapter.text", power.snapshot.adapterName, Int(watts)) : power.snapshot.adapterName
    }

    private var adapterInputParts: [DetailPart]? {
        guard power.snapshot.isPluggedIn else { return [.text(L10n.t("adapter.notConnected"))] }
        guard let watts = power.snapshot.adapterInputWatts else { return nil }

        var parts: [DetailPart] = [.number(watts, "%.2f"), .text(" W")]
        if let currentMa = power.snapshot.adapterInputCurrentMa,
           let voltage = power.snapshot.adapterInputVoltageVolts {
            parts.append(.text(" · "))
            parts.append(.number(currentMa, "%.0f"))
            parts.append(.text(" mA @ "))
            parts.append(.number(voltage, "%.1f"))
            parts.append(.text(" V"))
        }
        return parts
    }

    private var batteryCurrentParts: [DetailPart]? {
        guard let ma = power.snapshot.batteryCurrentMa else { return nil }
        let current = DetailPart.number(ma, "%.0f")
        switch power.snapshot.powerState {
        case .charging:
            return [.text("+"), current, .text(L10n.t("current.charging"))]
        case .adapterAssist:
            return [current, .text(L10n.t("current.assist"))]
        case .limitDischarge:
            return [current, .text(L10n.t("current.limitDischarge"))]
        case .chargeStopped:
            return abs(ma) < 10
                ? [.number(0, "%.0f"), .text(L10n.t("current.stoppedIdle"))]
                : [current, .text(L10n.t("current.stoppedCurrent"))]
        case .batteryOnly:
            return [current, .text(L10n.t("current.discharging"))]
        }
    }

    private var batteryPowerParts: [DetailPart]? {
        guard let voltage = power.snapshot.voltageVolts,
              let currentMa = power.snapshot.batteryCurrentMa else { return nil }
        let watts = voltage * currentMa / 1000.0
        if watts > 0.5 {
            return [.text("+"), .number(watts, "%.2f"), .text(L10n.t("power.intoBattery"))]
        }
        if watts < -0.5 {
            return [.number(watts, "%.2f"), .text(L10n.t("power.fromBattery"))]
        }
        return [.number(0, "%.2f"), .text(" W")]
    }

    private var capacityParts: [DetailPart]? {
        guard let current = power.snapshot.currentCapacityMah,
              let maxCapacity = power.snapshot.maxCapacityMah else { return nil }
        return [
            .number(Double(current), "%.0f"),
            .text(" / "),
            .number(Double(maxCapacity), "%.0f"),
            .text(" mAh")
        ]
    }

    private var designCapacityText: String {
        power.snapshot.designCapacityMah.map { "\($0) mAh" } ?? "—"
    }

    private func batteryColor(for percent: Int) -> Color {
        if percent <= 20 { return .red }
        if percent <= 50 { return .orange }
        return .green
    }

    private func temperatureColor(for celsius: Double?) -> Color {
        guard let celsius else { return .secondary }
        if celsius > 42.0 { return .red }
        if celsius > 36.0 { return .orange }
        return .green
    }
}

struct MetricTile: View {
    let title: String
    let value: Double?
    var format: String = "%.0f"
    var unit: String? = nil
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(tint)

            if let value {
                RollingNumberText(
                    value: value,
                    format: format,
                    suffix: unit ?? "",
                    unitSpacing: unit == "%" ? 1.0 : 2.0
                )
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .animation(ValueAnimation.curve, value: value)
            } else {
                Text("—")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
    }
}

enum DetailPart {
    case text(String)
    case number(Double, String)
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }
}

struct DetailValueRow: View {
    let label: String
    let parts: [DetailPart]

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 0) {
                ForEach(parts.indices, id: \.self) { index in
                    switch parts[index] {
                    case .text(let text):
                        Text(text)
                    case .number(let value, let format):
                        RollingNumberText(value: value, format: format)
                            .animation(ValueAnimation.curve, value: value)
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .monospacedDigit()
            .foregroundColor(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
        }
    }
}

struct AnimatedDetailRow: View {
    let label: String
    let value: Double?
    let format: String
    let suffix: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            if let value {
                RollingNumberText(value: value, format: format, suffix: suffix)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .animation(ValueAnimation.curve, value: value)
            } else {
                Text("—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
}
