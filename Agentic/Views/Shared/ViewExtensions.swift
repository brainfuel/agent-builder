import SwiftUI

extension View {
    /// Applies a `.help(...)` tooltip when running under Mac Catalyst; no-op elsewhere.
    /// Used across extracted views for consistent hover hints on Catalyst.
    @ViewBuilder
    func catalystTooltip(_ text: String) -> some View {
#if targetEnvironment(macCatalyst)
        self.help(text)
#else
        self
#endif
    }
}
