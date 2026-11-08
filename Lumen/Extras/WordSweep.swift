import SwiftUI

/// Bardzo powolne unoszenie się okładki (animacja idzie do systemu raz, bez pracy na klatkę).
struct FloatMotion: ViewModifier {
    var enabled: Bool
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .offset(y: enabled ? (phase ? -7 : 7) : 0)
            .rotation3DEffect(.degrees(enabled ? (phase ? 3 : -3) : 0), axis: (x: 0.2, y: 1, z: 0))
            .onAppear { restart() }
            .onChange(of: enabled) { _, _ in restart() }
    }

    private func restart() {
        phase = false
        guard enabled else { return }
        withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) { phase = true }
    }
}
