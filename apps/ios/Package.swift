// swift-tools-version: 5.9
//
// This manifest exists for one purpose: `swift test` on Linux, where there is
// no Xcode. It compiles the two directories of the app that need neither
// SwiftUI nor UIKit (Protocol and Model) under the app's own module name, so
// the same test files serve here and in the Xcode test bundle.
//
// It is not how the app is built. `project.yml` is the project, and
// `scripts/macos/test-ios.sh` and `build-ios.sh` are still the build.

import PackageDescription

let package = Package(
    name: "HouseholdAssistant",
    targets: [
        .target(
            name: "HouseholdAssistant",
            path: "HouseholdAssistant",
            // Everything that needs SwiftUI, UIKit or an Apple-only framework.
            exclude: [
                "Protocol/Fixtures",
                "App",
                "Demo",
                "Design",
                "Fonts",
                "Intents",
                "Media",
                "Views",
                "Voice",
                "Assets.xcassets",
                "HouseholdAssistantApp.swift",
            ],
            sources: ["Protocol", "Model"]
        ),
        .testTarget(
            name: "HouseholdAssistantTests",
            dependencies: ["HouseholdAssistant"],
            path: "HouseholdAssistantTests"
        ),
    ]
)
