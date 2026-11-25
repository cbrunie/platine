import SwiftUI

/// Les couleurs du thème sombre de l'app web DroppedNeedle (`frontend/src/app.css`).
extension Color {
    static let base100 = Color(hex: 0x0D120A)
    static let base200 = Color(hex: 0x161D12)
    static let base300 = Color(hex: 0x1F271B)
    static let sky = Color(hex: 0xAED5F2)
    static let skyContent = Color(hex: 0x071520)
    static let sage = Color(hex: 0xBBDB9B)

    init(hex: UInt32) {
        self.init(
            red: Double(hex >> 16 & 0xFF) / 255,
            green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Font {
    /// Space Grotesk, la police des titres du web (`--font-display`).
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .body,
                        weight: Font.Weight = .bold) -> Font {
        .custom("Space Grotesk", size: size, relativeTo: style).weight(weight)
    }
}

extension UIFont {
    static func display(_ size: CGFloat) -> UIFont {
        let bold = UIFontDescriptor(fontAttributes: [
            .family: "Space Grotesk",
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold],
        ])
        return UIFont(descriptor: bold, size: size)
    }
}

extension View {
    /// Le fond vert-noir des pages web, sous les listes comme sous les défilements.
    func platineBackground() -> some View {
        #if os(tvOS)
        background(
            LinearGradient(colors: [.base300, .base100], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
        #else
        scrollContentBackground(.hidden)
            .background(
                LinearGradient(colors: [.base300, .base100], startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
            )
        #endif
    }
}

/// Un titre de rayon en capitales espacées, comme « WHAT'S HOT » sur le web.
struct ShelfTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.display(12, relativeTo: .caption, weight: .semibold))
            .tracking(2)
            .foregroundStyle(.secondary)
    }
}

/// Une pastille colorée, comme « Recently Added » ou « FLAC ».
struct Pill: View {
    let text: String
    var color: Color = .sage

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: .capsule)
            .foregroundStyle(Color.base100)
    }
}
