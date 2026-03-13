import SwiftUI

private struct ThemedBackgroundModifier: ViewModifier {
    @AppStorage("uiTheme") private var uiTheme = UITheme.classicBlue.rawValue

    func body(content: Content) -> some View {
        content.background(selectedTheme.backgroundGradient.ignoresSafeArea())
    }

    private var selectedTheme: UITheme {
        UITheme(rawValue: uiTheme) ?? .classicBlue
    }
}

private struct ThemedScrollableBackgroundModifier: ViewModifier {
    @AppStorage("uiTheme") private var uiTheme = UITheme.classicBlue.rawValue

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(selectedTheme.backgroundGradient.ignoresSafeArea())
    }

    private var selectedTheme: UITheme {
        UITheme(rawValue: uiTheme) ?? .classicBlue
    }
}

extension View {
    func themedBackground() -> some View {
        modifier(ThemedBackgroundModifier())
    }

    func themedScrollableBackground() -> some View {
        modifier(ThemedScrollableBackgroundModifier())
    }
}

