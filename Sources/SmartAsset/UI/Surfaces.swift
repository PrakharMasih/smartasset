import SwiftUI

/// Surfaces the system does not provide (bama design-system). Chrome (sidebar, toolbar, sheets) stays Apple's.
enum Surface {
    /// The backdrop behind pictures: a step deeper than the window in dark mode and a step cooler in light mode, the way
    /// Photos and Lightroom let pictures stand out. Used only behind thumbnails and the Search page, never behind text-only pages.
    static var content: Color {
        Color(light: 0xF3F3F6, dark: 0x141416, highContrastLight: 0xFFFFFF, highContrastDark: 0x000000)
    }

    /// A soft wash of the accent, for the Search page behind its field. Stays quiet: it is a mood, not a color block.
    static var glow: RadialGradient {
        RadialGradient(colors: [Palette.accent.opacity(0.14), Palette.accent.opacity(0.0)],
                       center: .top, startRadius: 0, endRadius: 560)
    }
}

/// Corner radii, on the 4 pt grid. Inner radius = outer radius − inset.
enum Radius {
    /// Chips and small badges.
    static let xs: CGFloat = 4
    /// Controls.
    static let sm: CGFloat = 8
    /// Pictures, cards, the Search field in results.
    static let md: CGFloat = 12
    /// The large Search field on the Search page.
    static let lg: CGFloat = 16
}

extension View {
    /// The Search field's surface: Liquid Glass on macOS 26 and later (it is a floating control on the navigation layer),
    /// a quiet tinted fill before that.
    @ViewBuilder func fieldSurface(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
