import SwiftUI

struct AppearancePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var settings = model.settings
        SettingsPage("Appearance") {
            VStack(spacing: 16) {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Label(theme.name, systemImage: theme.symbol).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("appearance.theme")
                .accessibilityLabel("Theme")
                .accessibilityValue(settings.theme.name)
                Text(settings.theme.detail)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceChoice.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance.mode")
            }
            .padding(16)
            .rainbowGlass(in: RoundedRectangle(cornerRadius: 20))
            AppearancePreview(scheme: settings.appearance.colorScheme ?? scheme)
        }
    }
}
