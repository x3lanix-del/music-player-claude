import SwiftUI
import UIKit
import MediaPlayer
import AVKit

// MARK: - Liquid glass (native on iOS 26+, material fallback before)

struct GlassModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.ink) private var ink
    @Environment(\.materialStyle) private var material
    let shape: S
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if material {
            content.background(ink.opacity(0.16), in: shape)
        } else {
            glassBody(content)
        }
    }

    @ViewBuilder
    private func glassBody(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if interactive {
                content.glassEffect(Glass.regular.tint(ink.opacity(0.06)).interactive(), in: shape)
            } else {
                content.glassEffect(Glass.regular.tint(ink.opacity(0.06)), in: shape)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    /// Szkło "ręcznie" (iOS < 26): materiał + lekki połysk od góry + jasna krawędź z gradientu + miękki cień.
    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .background(
                shape.fill(
                    LinearGradient(colors: [ink.opacity(0.14), ink.opacity(0.03)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .overlay(
                // Połysk: jasny pas przy górnej krawędzi, który znika w dół.
                shape.fill(
                    LinearGradient(stops: [
                        .init(color: Color.white.opacity(0.22), location: 0),
                        .init(color: Color.white.opacity(0.04), location: 0.35),
                        .init(color: .clear, location: 0.6)
                    ], startPoint: .top, endPoint: .bottom)
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            )
            .overlay(
                // Krawędź załamująca światło: jaśniejsza u góry-lewo, ciemniejsza u dołu-prawo.
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.65), Color.white.opacity(0.12),
                                            Color.white.opacity(0.05), Color.white.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.9)
                .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func glass<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(GlassModifier(shape: shape, interactive: interactive))
    }

    func glassCard(radius: CGFloat = 22) -> some View {
        glass(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct GlassIconButton: View {
    @Environment(\.ink) private var ink
    let systemName: String
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: size, height: size)
                .glass(Circle(), interactive: true)
                .frame(width: max(size, 48), height: max(size, 48))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - System volume + AirPlay bridges

/// iOS has no API to set the system volume; a hidden MPVolumeView exposes its slider.
final class VolumeController: ObservableObject {
    @Published var level: Float = AVAudioSession.sharedInstance().outputVolume
    fileprivate weak var slider: UISlider?
    private var observation: NSKeyValueObservation?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            let v = change.newValue ?? 0
            DispatchQueue.main.async { self?.level = v }
        }
    }

    func set(_ value: Float) {
        level = value
        slider?.value = value
    }
}

struct HiddenVolumeView: UIViewRepresentable {
    let controller: VolumeController

    func makeUIView(context: Context) -> MPVolumeView {
        // Ukryty suwak głośności (do sterowania głośnością z aplikacji): poza ekranem i bez przycisku AirPlay,
        // żeby nic nie prześwitywało na środku.
        let v = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 1, height: 1))
        v.showsRouteButton = false
        v.alpha = 0.01
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak v] in
            if controller.slider == nil {
                controller.slider = v?.subviews.compactMap { $0 as? UISlider }.first
            }
        }
        return v
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        if controller.slider == nil {
            controller.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    var color: Color = .primary

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(color)
        v.activeTintColor = UIColor(color)
        return v
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = UIColor(color)
        view.activeTintColor = UIColor(color)
    }
}
