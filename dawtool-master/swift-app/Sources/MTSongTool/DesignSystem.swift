import SwiftUI
import AppKit

// MARK: - Colors
extension Color {
    // Adaptive colors: dark → light
    static let bg         = Color(adaptive: "#181818", light: "#f5f5f7")
    static let bgCard     = Color(adaptive: "#252525", light: "#ffffff")
    static let bgCardHov  = Color(adaptive: "#2d2d2d", light: "#f0f0f2")
    static let accent     = Color(adaptive: "#60a5fa", light: "#2563eb")
    static let accent2    = Color(adaptive: "#a78bfa", light: "#7c3aed")
    static let fgDim      = Color(adaptive: "#6b7280", light: "#9ca3af")
    static let fgMid      = Color(adaptive: "#9ca3af", light: "#6b7280")
    static let fgBright   = Color(adaptive: "#e5e7eb", light: "#1f2937")
    static let border     = Color(adaptive: "#333333", light: "#d1d5db")

    // Semantic colors
    static let inputBg     = Color(adaptive: "#1e1e1e", light: "#f9fafb")
    static let red         = Color(adaptive: "#f87171", light: "#b91c1c")
    static let redLight    = Color(adaptive: "#fca5a5", light: "#dc2626")
    static let redBg       = Color(adaptive: "#2a1515", light: "#fee2e2")
    static let redBgHov    = Color(adaptive: "#3a1a1a", light: "#fecaca")
    static let green       = Color(adaptive: "#22c55e", light: "#16a34a")
    static let greenLight  = Color(adaptive: "#34d399", light: "#16a34a")
    static let submitOff   = Color(adaptive: "#333333", light: "#d1d5db")
    static let submitOffFg = Color(adaptive: "#6b7280", light: "#9ca3af")
    static let dropHovBg   = Color(adaptive: "#16243a", light: "#eff6ff")
    static let dropHovIcon = Color(adaptive: "#93c5fd", light: "#2563eb")
    static let toastErrorBg = Color(adaptive: "#2a1515", light: "#fee2e2")
    static let toastComingBg = Color(adaptive: "#1e1040", light: "#f5f3ff")
    static let pressedBg   = Color(adaptive: "#141414", light: "#e5e7eb")

    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8)  & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Creates an adaptive color that switches between dark and light appearances.
    init(adaptive darkHex: String, light lightHex: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? darkHex : lightHex
            let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            var rgb: UInt64 = 0
            Scanner(string: h).scanHexInt64(&rgb)
            let r = CGFloat((rgb >> 16) & 0xFF) / 255
            let g = CGFloat((rgb >> 8)  & 0xFF) / 255
            let b = CGFloat( rgb        & 0xFF) / 255
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        })
    }
}

// MARK: - Font helpers
extension Font {
    static func horizon(size: CGFloat) -> Font {
        .custom("Horizon-Bold", size: size)
    }
    static func lato(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .bold, .semibold:
            return .custom("Lato-Bold", size: size)
        case .black, .heavy:
            return .custom("Lato-Black", size: size)
        case .light, .thin, .ultraLight:
            return .custom("Lato-Light", size: size)
        default:
            return .custom("Lato-Regular", size: size)
        }
    }
}

// MARK: - Hover-aware button wrapper
/// Adds @State hover tracking to any ButtonStyle via onHover.
struct HoverButtonStyle<Base: ButtonStyle>: ButtonStyle {
    let base: Base
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        base.makeBody(configuration: configuration)
            .brightness(isHovered && !configuration.isPressed ? 0.07 : 0)
            .onHover { h in
                withAnimation(.easeOut(duration: 0.12)) { isHovered = h }
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
    }
}

extension ButtonStyle {
    func hoverable() -> HoverButtonStyle<Self> {
        HoverButtonStyle(base: self)
    }
}

// MARK: - Primary button style
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lato(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color(hex: "#3b82f6") : Color.accent)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Secondary button style
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lato(size: 13, weight: .medium))
            .foregroundColor(configuration.isPressed ? Color.fgDim : Color.fgMid)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color.pressedBg : Color.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.border, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Compact secondary button style (for Copy All)
struct CompactSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lato(size: 10, weight: .medium))
            .foregroundColor(configuration.isPressed ? Color.fgDim : Color.fgMid)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed ? Color.pressedBg : Color.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.border, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Fixed-height secondary button style (background applied after frame for exact height match)
struct FixedHeightSecondaryButtonStyle: ButtonStyle {
    let height: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lato(size: 13, weight: .medium))
            .foregroundColor(configuration.isPressed ? Color.fgDim : Color.fgMid)
            .padding(.horizontal, 20)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color.pressedBg : Color.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.border, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Card background modifier
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.bgCard)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.border, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardBackground())
    }
}
