import SwiftUI

/// Shared pill-shaped label used by the header bar and schema controls bar.
struct HeaderControlLabel: View {
    let title: String
    let systemImage: String
    let height: CGFloat
    let prominent: Bool
    let enabled: Bool
    var destructive: Bool = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: height)
            .foregroundStyle(HeaderControlStyle.foreground(prominent: prominent, enabled: enabled, destructive: destructive))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(HeaderControlStyle.background(prominent: prominent, enabled: enabled))
            )
    }
}

enum HeaderControlStyle {
    static func foreground(prominent: Bool, enabled: Bool, destructive: Bool = false) -> Color {
        if !enabled {
            return Color(uiColor: .tertiaryLabel)
        }
        if prominent {
            return .white
        }
        if destructive {
            return .red
        }
        return AppTheme.brandTint
    }

    static func background(prominent: Bool, enabled: Bool) -> Color {
        if prominent {
            return enabled ? AppTheme.brandTint : AppTheme.brandTint.opacity(0.45)
        }
        return enabled
            ? AppTheme.surfaceSecondary
            : Color(uiColor: .tertiarySystemFill)
    }
}
