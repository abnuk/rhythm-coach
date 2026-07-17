import SwiftUI

@main
struct RhythmCoachApp: App {
    @State private var transport = TransportController()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(transport)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .windowResizability(.contentMinSize)
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case practice = "Practice"
    case history = "History"
    case audio = "Audio Setup"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .practice: "metronome"
        case .history: "chart.line.uptrend.xyaxis"
        case .audio: "hifispeaker.2"
        }
    }
}

struct MainView: View {
    @Environment(TransportController.self) private var transport
    @AppStorage("ui.screen") private var screen: Screen = .practice

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $screen) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
        } detail: {
            switch screen {
            case .practice: PracticeView()
            case .history: HistoryView()
            case .audio: AudioPreferencesView()
            }
        }
        .navigationTitle("RhythmCoach")
    }
}
