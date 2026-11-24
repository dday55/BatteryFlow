import SwiftUI

/// Global numeric value easing.
///
/// A spring keeps velocity across the 1-second sample boundaries, so values glide instead of
/// restarting from zero. The response must stay below the 1-second sampling interval: with a
/// longer response the spring never settles, the display link runs continuously and the app
/// burns CPU even while the panel is closed. 0.6s settles between samples.
enum ValueAnimation {
    static let response: Double = 0.6
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
