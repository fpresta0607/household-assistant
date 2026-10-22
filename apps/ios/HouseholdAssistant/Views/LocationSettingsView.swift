// Location, from Settings and from the indicator on Chats: whether this iPhone shares
// where it is, with whom and for how long, paused or stopped, in plain words. It is off
// until its person turns it on, and each person decides for their own iPhone.
//
// Precise Location is a switch of the app's own: off sends only the neighbourhood, and on
// asks iOS for precise, saying plainly when iOS keeps it approximate. Whether the app may
// use location at all, and hears moves while closed, is iOS's to decide, so that is shown
// here and changed there.

import SwiftUI
import UIKit

struct LocationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.reducesMotion) private var reduceMotion
    /// What a share starts with while sharing is off. Once it is on, the share's own.
    @State private var audience: LocationAudience = .assistant
    @State private var span: LocationSpan = .hour
    @State private var isWorking = false

    var body: some View {
        let sharing = model.location.sharing
        SettingsPage("Location") {
            header
            SettingsGroup(refusal: model.location.errorText) {
                SettingsRow("Share my location", subtitle: model.locationState.sentence(assistant: model.assistantName)) {
                    Toggle("Share my location", isOn: isOn.animation(Motion.flip(reduced: reduceMotion)))
                        .labelsHidden()
                }
                if let sharing {
                    Button {
                        run {
                            if sharing.isPaused {
                                await model.location.resume()
                            } else {
                                await model.location.pause()
                            }
                        }
                    } label: {
                        SettingsRow(sharing.isPaused ? "Resume sharing" : "Pause sharing") {
                            Image(systemName: sharing.isPaused ? "play.fill" : "pause.fill")
                                .foregroundStyle(Palette.highlight)
                        } trailing: {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.settingsRow)
                }
            }
            if let note = LocationAlwaysAsk.closedAppNote(sharing: sharing, isAlways: model.permissions.isLocationAlways, at: Date()) {
                Label(note, systemImage: "moon.zzz.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, 4)
            }
            SettingsGroup("With") {
                ForEach(LocationAudience.allCases, id: \.self) { option in
                    let isChosen = chosenAudience.wrappedValue == option
                    Button {
                        chosenAudience.wrappedValue = option
                    } label: {
                        SettingsRow(
                            option.title(assistant: model.assistantName),
                            subtitle: option.detail(assistant: model.assistantName, otherPerson: model.otherPersonName)
                        ) {
                            if isChosen {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Palette.highlight)
                            }
                        }
                    }
                    .buttonStyle(.settingsRow)
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
                }
            }
            SettingsGroup(
                "For how long",
                note: "It stops by itself when the time is up. Until tonight ends at midnight, and Always runs until you stop it."
            ) {
                GlassSegmentedControl(choices: LocationSpan.allCases, selection: chosenSpan) { $0.title }
                    .padding(10)
            }
            SettingsGroup(
                "On this iPhone",
                note: "With While Using only, \(model.assistantName) hears where you are only while the app is open. What iOS allows changes in iOS Settings."
            ) {
                SettingsRow("Allowed") {
                    RowValue(text: allowed, opensPage: false)
                }
                SettingsRow("Precise Location", subtitle: model.locationPrecision.words(assistant: model.assistantName)) {
                    Toggle("Precise Location", isOn: isPrecise.animation(Motion.flip(reduced: reduceMotion)))
                        .labelsHidden()
                }
                // iOS decides these, so changing one happens on the app's own page there.
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingsRow("Change in iOS Settings") {
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(Palette.highlight)
                    }
                }
                .buttonStyle(.settingsRow)
            }
            Text(promise)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 4)
            if sharing != nil {
                SettingsGroup {
                    Button(role: .destructive) {
                        run {
                            await model.location.stop()
                        }
                    } label: {
                        Label("Stop sharing", systemImage: "location.slash.fill")
                            .font(.body)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.settingsRow)
                }
            }
        }
        .disabled(isWorking)
        .animation(Motion.arrive(reduced: reduceMotion), value: sharing)
        .task {
            await model.permissions.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from iOS Settings: show what changed there.
            if phase == .active {
                Task {
                    await model.permissions.refresh()
                }
            }
        }
    }

    /// The big symbol and the promise in one line, as the mockup draws it.
    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "location.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Palette.highlight)
                .frame(width: 84, height: 84)
                .rainbowGlass(in: Circle())
                .accessibilityHidden(true)
            Text("Off until you turn it on. Each person decides for their own iPhone.")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// Exactly what is shared, with whom and for how long.
    private var promise: String {
        let assistant = model.assistantName
        return "Your iPhone sends where it is to \(assistant) on your household's own server and to nobody else, "
            + "only after you move a fair way or arrive somewhere, and never while paused. "
            + "\(assistant) keeps only the latest, with its time and how exact it is, and forgets it when you pause, "
            + "stop, or the time is up. The app sends it nowhere else, Apple included, and never to \(model.otherPersonName)'s assistant."
    }

    private var allowed: String {
        switch model.permissions.status(of: .location) {
        case .notAsked:
            return "Not asked"
        case .denied:
            return "Never"
        case .allowed:
            return model.permissions.isLocationAlways ? "Always" : "While using the app"
        }
    }

    private var isOn: Binding<Bool> {
        Binding {
            model.location.sharing != nil
        } set: { isOn in
            run {
                if isOn {
                    await model.shareLocation(with: audience, for: span)
                } else {
                    await model.location.stop()
                }
            }
        }
    }

    private var isPrecise: Binding<Bool> {
        Binding {
            model.location.isPrecise
        } set: { isPrecise in
            run {
                await model.sharePrecisely(isPrecise)
            }
        }
    }

    private var chosenAudience: Binding<LocationAudience> {
        Binding {
            model.location.sharing?.audience ?? audience
        } set: { chosen in
            audience = chosen
            if model.location.sharing != nil {
                run {
                    await model.location.share(with: chosen)
                }
            }
        }
    }

    private var chosenSpan: Binding<LocationSpan> {
        Binding {
            model.location.sharing?.span ?? span
        } set: { chosen in
            span = chosen
            if model.location.sharing != nil {
                run {
                    await model.location.share(for: chosen)
                }
            }
        }
    }

    /// One change at a time, so a second tap cannot race the first one's report.
    private func run(_ work: @escaping @MainActor () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }
}
