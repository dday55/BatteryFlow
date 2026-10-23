import SwiftUI

/// Global numeric value easing.
///
/// Uses a critically damped spring with a long response rather than a fixed-duration easeInOut:
/// Under 1-second sampling, easeInOut performs a "start-stop" every second; a spring carries over
/// velocity from the previous transition, delivering a continuous gliding feel as targets change.
/// A larger response gives a smoother transition (recommended: 1.3–2.0).
enum ValueAnimation {
    static let response: Double = 2.4
    static var curve: Animation { .spring(response: response, dampingFraction: 1.0) }
}

/// Dynamic numeric text component supporting smooth scrolling animation.
///
/// `@preconcurrency` is only used to silence cross-isolation diagnostics between
/// `View` (main-actor isolated) and `Animatable` (non-isolated) under Swift 6 strict concurrency;
/// this type is only used within the SwiftUI main-thread rendering path.
public struct RollingNumberText: View, @preconcurrency Animatable {
    public var value: Double
    public var format: String
    public var suffix: String
    public var unitSpacing: CGFloat

    public init(value: Double, format: String, suffix: String = "", unitSpacing: CGFloat = 2.5) {
        self.value = value
        self.format = format
        self.suffix = suffix
        self.unitSpacing = unitSpacing
    }

    public var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    public var body: some View {
        let trimmedSuffix = suffix.trimmingCharacters(in: .whitespaces)
        if !trimmedSuffix.isEmpty && unitSpacing > 0 {
            HStack(alignment: .firstTextBaseline, spacing: unitSpacing) {
                Text(String(format: format, value))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(trimmedSuffix)
            }
        } else {
            Text(String(format: format, value) + suffix)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}
