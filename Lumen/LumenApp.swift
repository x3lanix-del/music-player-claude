import SwiftUI

@main
@MainActor
struct LumenApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var toast: ToastCenter
    @StateObject private var engine: PlayerEngine
    @StateObject private var library = LibraryStore()
    @StateObject private var volume = VolumeController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = Reachability.shared      // monitor sieci startuje od razu
        let s = AppSettings()
        let t = ToastCenter()
        _settings = StateObject(wrappedValue: s)
        _toast = StateObject(wrappedValue: t)
        _engine = StateObject(wrappedValue: PlayerEngine(settings: s, toast: t))
        Task.detached(priority: .utility) { await StreamResolver.shared.warmUp() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(toast)
                .environmentObject(engine)
                .environmentObject(library)
                .environmentObject(volume)
                .preferredColorScheme(settings.colorScheme)
                .appColors(settings)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }   // ekran nie przygasa i nie wyłącza się
                .onChange(of: scenePhase) { _, phase in
                    UIApplication.shared.isIdleTimerDisabled = (phase == .active)
                }
                .task { _ = await LyricsAligner.authorize() }   // prośba o zgodę na rozpoznawanie mowy przy starcie
        }
    }
}
