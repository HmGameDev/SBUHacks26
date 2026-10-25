import AppIntents

// Siri control: the screen faces the user's chest while walking, so nobody can tap it.
// Every intent opens the app because ARKit only runs in the foreground.

struct StartGuidanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Guidance"
    static var description = IntentDescription("Starts obstacle guidance in the current mode.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.start()
        return .result()
    }
}

struct StopGuidanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Guidance"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.stop(announce: true)
        return .result()
    }
}

struct PassiveModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Passive Mode"
    static var description = IntentDescription("Obstacle guidance with no destination.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        model.setMode(.passive)
        model.start()
        return .result()
    }
}

struct NavigateIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Navigation"
    static var description = IntentDescription("Walking directions to a place, with obstacle guidance on the way.")
    static var openAppWhenRun = true

    @Parameter(title: "Destination", requestValueDialog: "Where to?")
    var destination: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.navigate(to: destination)
        return .result()
    }
}

struct StopNavigationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Navigation"
    static var description = IntentDescription("Ends the route. Obstacle guidance keeps running.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.stopNavigation()
        return .result()
    }
}

struct RepeatDirectionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Where Am I Going"
    static var description = IntentDescription("Repeats the next turn and the distance left.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.repeatDirections()
        return .result()
    }
}

struct QuieterIntent: AppIntent {
    static var title: LocalizedStringResource = "Quieter"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.quieter()
        return .result()
    }
}

struct MoreDetailIntent: AppIntent {
    static var title: LocalizedStringResource = "More Detail"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.moreDetail()
        return .result()
    }
}

struct ScoutShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartGuidanceIntent(),
            phrases: ["Start \(.applicationName)", "Start guidance with \(.applicationName)"],
            shortTitle: "Start",
            systemImageName: "figure.walk"
        )
        AppShortcut(
            intent: StopGuidanceIntent(),
            phrases: ["Stop \(.applicationName)", "Stop guidance with \(.applicationName)"],
            shortTitle: "Stop",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: PassiveModeIntent(),
            phrases: ["\(.applicationName) passive mode", "Passive mode in \(.applicationName)"],
            shortTitle: "Passive Mode",
            systemImageName: "figure.walk.motion"
        )
        AppShortcut(
            intent: NavigateIntent(),
            phrases: [
                "Start navigation with \(.applicationName)",
                "Start navigation in \(.applicationName)",
                "Navigate with \(.applicationName)",
                "\(.applicationName) take me somewhere",
            ],
            shortTitle: "Start Navigation",
            systemImageName: "map"
        )
        AppShortcut(
            intent: StopNavigationIntent(),
            phrases: ["Stop navigation in \(.applicationName)", "Stop navigation with \(.applicationName)", "\(.applicationName) stop navigation"],
            shortTitle: "Stop Navigation",
            systemImageName: "map.slash"
        )
        AppShortcut(
            intent: RepeatDirectionsIntent(),
            phrases: ["Where am I going in \(.applicationName)", "\(.applicationName) where am I going", "\(.applicationName) repeat directions"],
            shortTitle: "Where Am I Going",
            systemImageName: "signpost.right"
        )
        AppShortcut(
            intent: QuieterIntent(),
            phrases: ["\(.applicationName) quieter", "Make \(.applicationName) quieter"],
            shortTitle: "Quieter",
            systemImageName: "speaker.wave.1"
        )
        AppShortcut(
            intent: MoreDetailIntent(),
            phrases: ["\(.applicationName) more detail", "More detail in \(.applicationName)"],
            shortTitle: "More Detail",
            systemImageName: "speaker.wave.3"
        )
    }
}
