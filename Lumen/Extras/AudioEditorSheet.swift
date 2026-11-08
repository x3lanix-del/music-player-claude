import SwiftUI

/// Prosty edytor dźwięku: szybkość i wysokość tonu (slowed, nightcore, speed up).
struct AudioEditorSheet: View {
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var rate: Double = 1
    @State private var keepPitch = true

    private struct Preset: Identifiable {
        let id: String
        let title: String
        let rate: Double
        let keepPitch: Bool
    }

    private let presets: [Preset] = [
        Preset(id: "normal", title: "Normalnie", rate: 1.0, keepPitch: true),
        Preset(id: "slowed", title: "Slowed (wolniej, niższy ton)", rate: 0.85, keepPitch: false),
        Preset(id: "slow", title: "Wolniej (ten sam ton)", rate: 0.85, keepPitch: true),
        Preset(id: "fast", title: "Szybciej (ten sam ton)", rate: 1.15, keepPitch: true),
        Preset(id: "nightcore", title: "Nightcore (szybciej, wyższy ton)", rate: 1.25, keepPitch: false)
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Gotowe ustawienia") {
                    ForEach(presets) { p in
                        Button {
                            rate = p.rate
                            keepPitch = p.keepPitch
                            apply()
                        } label: {
                            HStack {
                                Text(p.title)
                                Spacer()
                                if abs(rate - p.rate) < 0.001 && keepPitch == p.keepPitch {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Section("Własne") {
                    VStack(alignment: .leading) {
                        Text("Szybkość: \(String(format: "%.2f", rate))×")
                        Slider(value: $rate, in: 0.5...2.0, step: 0.05) { editing in
                            if !editing { apply() }
                        }
                    }
                    Toggle("Zachowaj wysokość tonu", isOn: $keepPitch)
                        .onChange(of: keepPitch) { _, _ in apply() }
                }
            }
            .navigationTitle("Edytor dźwięku")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Gotowe") { dismiss() } } }
            .onAppear {
                rate = settings.data.playbackRate
                keepPitch = settings.data.keepPitch
            }
        }
    }

    private func apply() {
        settings.data.playbackRate = rate
        settings.data.keepPitch = keepPitch
        engine.setPlayback(rate: rate, keepPitch: keepPitch)
    }
}
