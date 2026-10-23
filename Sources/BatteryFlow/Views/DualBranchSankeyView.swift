import SwiftUI

/// Combined value driving geometry interpolation (smooth transition triggered whenever any branch changes)
private struct SankeyLevels: Equatable {
    let battery: Double
    let system: Double
}

/// Minimalist dual-branch Sankey diagram component for power routing (with dynamic particle animation and pixel-level geometric alignment)
public struct DualBranchSankeyView: View {
    public let sourceWatts: Double
    public let batteryWatts: Double
    public let systemWatts: Double
    public let powerState: PowerState
    public let isPluggedIn: Bool

    private var isBypassActive: Bool { powerState == .chargeStopped }

    // Node card dimension constants to ensure seamless geometric continuity
    private let cardWidth: CGFloat = 96
    private let cardHeight: CGFloat = 42
    private let canvasHeight: CGFloat = 114

    public init(
        sourceWatts: Double,
        batteryWatts: Double,
        systemWatts: Double,
        powerState: PowerState,
        isPluggedIn: Bool
    ) {
        self.sourceWatts = sourceWatts
        self.batteryWatts = batteryWatts
        self.systemWatts = systemWatts
        self.powerState = powerState
        self.isPluggedIn = isPluggedIn
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.accentColor)
                    Text(L10n.t("sankey.title"))
                        .font(.system(size: 13, weight: .semibold))
                }
                
                Spacer()
                
                if isBypassActive {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 11))
                        Text(L10n.t("sankey.bypass"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.1, green: 0.75, blue: 0.45))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(4)
                } else if powerState == .limitDischarge {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                        Text(L10n.t("sankey.limitDischarge"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.1, green: 0.55, blue: 0.95))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12))
                    .cornerRadius(4)
                } else if powerState == .adapterAssist {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text(L10n.t("sankey.adapterAssist"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(4)
                } else if !isPluggedIn {
                    HStack(spacing: 4) {
                        Image(systemName: "battery.100")
                            .font(.system(size: 11))
                        Text(L10n.t("sankey.batteryOnly"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                        Text(L10n.t("sankey.charging"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12))
                    .cornerRadius(4)
                }
            }

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                let leftCenterY = h / 2
                let topRightCenterY = cardHeight / 2
                let bottomRightCenterY = h - (cardHeight / 2)

                // Extend 8pt into cards so band ends are cleanly concealed behind solid card backgrounds
                let startX = cardWidth - 8
                let endX = w - cardWidth + 8

                let total = max(0.1, abs(batteryWatts) + systemWatts)
                let batRatio = CGFloat(batteryWatts / total)
                let sysRatio = CGFloat(systemWatts / total)

                let isBatteryDischarging = batteryWatts < -0.05
                let maxThickness: CGFloat = 26
                let batteryThickness: CGFloat = batteryWatts > 0 ? max(6, batRatio * maxThickness) : 0
                let systemThickness: CGFloat = max(8, sysRatio * maxThickness)
                let totalInputThickness = batteryThickness + systemThickness

                // When plugged in and the battery is discharging, draw a reverse band
                // from the battery card back into the mixed supply node so the energy
                // chain reads clearly: battery -> bus -> system.
                let dischargeWatts = max(0.0, -batteryWatts)
                let reverseThickness: CGFloat = (isPluggedIn && dischargeWatts > 0.5)
                    ? max(6, CGFloat(dischargeWatts / total) * maxThickness)
                    : 0
                let showReverse = reverseThickness > 0.5

                ZStack {
                    // Discharge feedback: battery feeds back into the mixed supply bus.
                    if showReverse {
                        SankeyFlowBand(
                            startX: endX,
                            startY: topRightCenterY,
                            endX: startX,
                            endY: leftCenterY,
                            startThickness: reverseThickness,
                            endThickness: reverseThickness
                        )
                        .fill(
                            LinearGradient(
                                // Warm orange marks reverse battery feedback, distinct from the blue/green forward flows.
                                colors: [
                                    Color(red: 1.00, green: 0.58, blue: 0.16).opacity(0.52),
                                    Color(red: 0.95, green: 0.38, blue: 0.06).opacity(0.40)
                                ],
                                startPoint: .trailing,
                                endPoint: .leading
                            )
                        )
                    }

                    // Retain thickness 0 view for smooth 0 <-> n growth via Animatable
                    let batStartY = leftCenterY - (totalInputThickness / 2) + (batteryThickness / 2)
                    SankeyFlowBand(
                        startX: startX,
                        startY: batStartY,
                        endX: endX,
                        endY: topRightCenterY,
                        startThickness: batteryThickness,
                        endThickness: batteryThickness
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.35),
                                Color(red: 0.1, green: 0.78, blue: 0.48).opacity(0.45)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                    let sysStartY = batteryThickness > 0
                        ? leftCenterY + (totalInputThickness / 2) - (systemThickness / 2)
                        : leftCenterY

                    SankeyFlowBand(
                        startX: startX,
                        startY: sysStartY,
                        endX: endX,
                        endY: bottomRightCenterY,
                        startThickness: systemThickness,
                        endThickness: systemThickness
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.35),
                                Color(red: 0.15, green: 0.55, blue: 0.98).opacity(0.50)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                    // Flow bubbles: sole dynamic layer (no scanline/ripple to prevent brightness flickering)
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate

                        ZStack {
                            if batteryThickness > 0.5 {
                                SankeyBubbles(
                                    startX: startX,
                                    startY: batStartY,
                                    endX: endX,
                                    endY: topRightCenterY,
                                    startThickness: batteryThickness,
                                    endThickness: batteryThickness,
                                    time: t,
                                    count: 5
                                )
                            }

                            SankeyBubbles(
                                startX: startX,
                                startY: sysStartY,
                                endX: endX,
                                endY: bottomRightCenterY,
                                startThickness: systemThickness,
                                endThickness: systemThickness,
                                time: t,
                                count: 6
                            )

                            if showReverse {
                                // Reverse direction: battery (right) back into the mixed supply (left).
                                SankeyBubbles(
                                    startX: endX,
                                    startY: topRightCenterY,
                                    endX: startX,
                                    endY: leftCenterY,
                                    startThickness: reverseThickness,
                                    endThickness: reverseThickness,
                                    time: t,
                                    count: 4
                                )
                            }
                        }
                        .allowsHitTesting(false)
                    }

                    SankeyPill(
                        title: isPluggedIn
                            ? (isBatteryDischarging ? L10n.t("sankey.mixedSupply") : L10n.t("sankey.bus"))
                            : L10n.t("sankey.batteryOutput"),
                        watts: sourceWatts,
                        icon: isPluggedIn ? "bolt.fill" : "battery.100",
                        tint: .accentColor,
                        width: cardWidth,
                        height: cardHeight
                    )
                    .position(x: cardWidth / 2, y: leftCenterY)

                    SankeyPill(
                        title: isBatteryDischarging ? L10n.t("sankey.batteryDischarge") : L10n.t("sankey.batteryCharge"),
                        watts: batteryWatts,
                        icon: isBatteryDischarging
                            ? "arrow.down.circle.fill"
                            : (isBypassActive ? "pause.circle.fill" : "battery.50"),
                        tint: isBatteryDischarging
                            ? Color(red: 0.15, green: 0.55, blue: 0.98)
                            : (isBypassActive ? .secondary : Color(red: 0.1, green: 0.75, blue: 0.45)),
                        width: cardWidth,
                        height: cardHeight
                    )
                    .position(x: w - (cardWidth / 2), y: topRightCenterY)

                    SankeyPill(
                        title: L10n.t("sankey.system"),
                        watts: systemWatts,
                        icon: "laptopcomputer",
                        tint: Color(red: 0.15, green: 0.55, blue: 0.98),
                        width: cardWidth,
                        height: cardHeight
                    )
                    .position(x: w - (cardWidth / 2), y: bottomRightCenterY)
                }
                .animation(ValueAnimation.curve, value: SankeyLevels(battery: batteryWatts, system: systemWatts))
            }
            .frame(height: canvasHeight)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

// MARK: - Flow Bubbles (Sole dynamic layer: soft, slow drifting)

private struct SankeyBubbles: View, @preconcurrency Animatable {
    var startX: CGFloat
    var startY: CGFloat
    var endX: CGFloat
    var endY: CGFloat
    var startThickness: CGFloat
    var endThickness: CGFloat
    var time: Double
    var count: Int

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(startY, endY),
                AnimatablePair(startThickness, endThickness)
            )
        }
        set {
            startY = newValue.first.first
            endY = newValue.first.second
            startThickness = newValue.second.first
            endThickness = newValue.second.second
        }
    }

    var body: some View {
        Canvas { context, _ in
            // Subtle blur to eliminate hard edges and subpixel shimmering
            context.addFilter(.blur(radius: 0.7))

            let midX = (startX + endX) * 0.5
            let start = CGPoint(x: startX, y: startY)
            let control1 = CGPoint(x: midX, y: startY)
            let control2 = CGPoint(x: midX, y: endY)
            let end = CGPoint(x: endX, y: endY)

            for index in 0..<count {
                // Slow, asynchronous drift: 0.18–0.28 rev/s
                let speed = 0.18 + Double(index % 3) * 0.05
                let rawT = Double(index) / Double(count) + time * speed
                let t = CGFloat(rawT - floor(rawT))

                let point = cubicBezierPoint(
                    t: t,
                    start: start,
                    control1: control1,
                    control2: control2,
                    end: end
                )
                let thickness = startThickness + (endThickness - startThickness) * t

                // Gentle horizontal wobble and layering to avoid aligning in a single row
                let wobble = CGFloat(sin(Double(index) * 2.0 + time * 0.8)) * thickness * 0.16
                let layerBias = (CGFloat(index % 4) / 3.0 - 0.5) * thickness * 0.36
                let y = point.y + wobble + layerBias

                // Fade at ends to prevent abrupt appearance/disappearance
                let fade = CGFloat(sin(Double(t) * .pi))
                let radius = CGFloat(1.5 + Double(index % 3) * 0.55)
                let haloAlpha = 0.14 * fade
                let coreAlpha = 0.46 * fade
                guard coreAlpha > 0.01 else { continue }

                // Soft outer glow + bright inner core: visual appearance of liquid bubbles
                let haloRadius = radius * 1.9
                let haloRect = CGRect(
                    x: point.x - haloRadius,
                    y: y - haloRadius,
                    width: haloRadius * 2,
                    height: haloRadius * 2
                )
                context.fill(
                    Path(ellipseIn: haloRect),
                    with: .color(.white.opacity(Double(haloAlpha)))
                )

                let coreRect = CGRect(
                    x: point.x - radius,
                    y: y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(
                    Path(ellipseIn: coreRect),
                    with: .color(.white.opacity(Double(coreAlpha)))
                )
            }
        }
    }
}

private func cubicBezierPoint(
    t: CGFloat,
    start: CGPoint,
    control1: CGPoint,
    control2: CGPoint,
    end: CGPoint
) -> CGPoint {
    let mt = 1 - t
    let a = mt * mt * mt
    let b = 3 * mt * mt * t
    let c = 3 * mt * t * t
    let d = t * t * t
    return CGPoint(
        x: a * start.x + b * control1.x + c * control2.x + d * end.x,
        y: a * start.y + b * control1.y + c * control2.y + d * end.y
    )
}

// MARK: - Native Cubic Bezier Flow Band Shape

struct SankeyFlowBand: Shape, Animatable {
    var startX: CGFloat
    var startY: CGFloat
    var endX: CGFloat
    var endY: CGFloat
    var startThickness: CGFloat
    var endThickness: CGFloat

    /// Interpolates band thickness and vertical coordinates between samples to avoid abrupt 1s jumps
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(startY, endY),
                AnimatablePair(startThickness, endThickness)
            )
        }
        set {
            startY = newValue.first.first
            endY = newValue.first.second
            startThickness = newValue.second.first
            endThickness = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midX = (startX + endX) * 0.5

        path.move(to: CGPoint(x: startX, y: startY - startThickness / 2))
        path.addCurve(
            to: CGPoint(x: endX, y: endY - endThickness / 2),
            control1: CGPoint(x: midX, y: startY - startThickness / 2),
            control2: CGPoint(x: midX, y: endY - endThickness / 2)
        )

        path.addLine(to: CGPoint(x: endX, y: endY + endThickness / 2))

        path.addCurve(
            to: CGPoint(x: startX, y: startY + startThickness / 2),
            control1: CGPoint(x: midX, y: endY + endThickness / 2),
            control2: CGPoint(x: midX, y: startY + startThickness / 2)
        )
        path.closeSubpath()
        return path
    }
}

struct SankeyPill: View {
    let title: String
    let watts: Double
    let icon: String
    let tint: Color
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(tint)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                
                RollingNumberText(value: watts, format: "%.1f", suffix: "W", unitSpacing: 2.5)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                    .animation(ValueAnimation.curve, value: watts)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: width, height: height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1.5)
        )
    }
}
