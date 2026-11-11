import SwiftUI
import UIKit

// =====================================================================================================
// Przewodnik po aplikacji: aplikacja sama przechodzi po zakładkach, podświetla kolejne elementy,
// wskazuje je strzałką i w dymku opisuje, do czego służą. "Dalej" (albo dotknięcie podświetlonego
// elementu) przechodzi do następnego kroku.
// =====================================================================================================

// MARK: - Elementy, które przewodnik może wskazać

enum TourTarget: Hashable {
    case tabBar
    case tab(AppTab)
    case surprise
    case searchField
    case recognize
    case libraryAdd
    case miniPlayer
}

struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]

    static func reduce(value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Oznacza element, który przewodnik może podświetlić i wskazać strzałką.
    /// (Dopisuje się do miejsc zgłoszonych przez elementy w środku, zamiast je zastępować.)
    func tourTarget(_ target: TourTarget) -> some View {
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { anchors, anchor in
            anchors[target] = anchor
        }
    }
}

// MARK: - Stan przewodnika

final class TourCenter: ObservableObject {
    /// Numer kroku (nil = przewodnik wyłączony).
    @Published private(set) var index: Int? = nil

    func start() { index = 0 }

    func stop() { index = nil }

    func next() {
        guard let i = index else { return }
        index = i + 1 < TourStep.all.count ? i + 1 : nil
    }

    func back() {
        guard let i = index, i > 0 else { return }
        index = i - 1
    }
}

// MARK: - Kroki

struct TourStep {
    /// Zakładka, na której aplikacja ma być w tym kroku (przełącza się sama).
    let tab: AppTab
    /// Co podświetlić i wskazać strzałką (nil = sam dymek).
    var target: TourTarget? = nil
    let icon: String
    let title: String
    let text: String
    /// Pokaż w dymku małe, ruchome demo tekstu piosenki.
    var demo = false
    /// Dymek na dole ekranu (żeby nie zasłaniał tego, o czym mowa).
    var bottom = false

    static let all: [TourStep] = [
        TourStep(tab: .home, icon: "hand.wave.fill", title: "Cześć!",
                 text: "Oprowadzę Cię po aplikacji i pokażę po kolei wszystkie funkcje. Dotykaj „Dalej” - to zajmie minutę."),
        TourStep(tab: .home, target: .tabBar, icon: "square.grid.2x2.fill", title: "Zakładki",
                 text: "Tu na dole przełączasz ekrany: Główna, Biblioteka, Radio, Szukaj i Ustawienia."),
        TourStep(tab: .home, target: .surprise, icon: "house.fill", title: "Główna",
                 text: "Na tym ekranie są ostatnio grane piosenki i to, co jest teraz na czasie. „Zaskocz mnie” włącza losowy miks."),
        TourStep(tab: .search, target: .searchField, icon: "magnifyingglass", title: "Szukaj",
                 text: "Wpisz piosenkę albo wykonawcę i naciśnij Szukaj. Dotknij wyniku, żeby go włączyć. Trzy kropki przy piosence: zagraj jako następną, dodaj do kolejki albo do playlisty. Możesz też wkleić link z YouTube lub Spotify."),
        TourStep(tab: .search, target: .recognize, icon: "waveform.circle.fill", title: "Co to za piosenka?",
                 text: "Gra coś obok Ciebie? Ten przycisk rozpozna piosenkę przez mikrofon."),
        TourStep(tab: .library, target: .libraryAdd, icon: "music.note.list", title: "Biblioteka",
                 text: "Tu są Twoje playlisty i Ulubione. Plus tworzy nową playlistę albo importuje ją z linku (YouTube, Spotify). Przytrzymaj playlistę, żeby zmienić nazwę, ikonę albo ją udostępnić."),
        TourStep(tab: .radio, target: .tab(.radio), icon: "dot.radiowaves.left.and.right", title: "Radio",
                 text: "Stacje radiowe na żywo. Aplikacja pokazuje, co teraz leci, i tekst tej piosenki."),
        TourStep(tab: .home, target: .miniPlayer, icon: "play.circle.fill", title: "Odtwarzacz",
                 text: "Gdy coś gra, nad zakładkami pojawia się mały pasek z piosenką. Dotknij go, żeby otworzyć duży odtwarzacz: tekst, kolejka, serce (ulubione) i głośniki. Muzyka gra też po zablokowaniu telefonu."),
        TourStep(tab: .home, icon: "quote.bubble.fill", title: "Tekst piosenki",
                 text: "Tekst zapala się dokładnie wtedy, gdy jest śpiewany. Dotknij linijki, żeby przeskoczyć w to miejsce piosenki. Możesz go też przewijać palcem - po chwili sam wróci.",
                 demo: true),
        TourStep(tab: .home, icon: "ellipsis.circle.fill", title: "Menu ••• w odtwarzaczu",
                 text: "Znajdziesz tam: inną wersję tekstu, tekst wcześniej lub później, tłumaczenie, wyłącznik czasowy (muzyka sama ścichnie) i edytor dźwięku (wolniej, szybciej)."),
        TourStep(tab: .home, target: .tab(.settings), icon: "gearshape.fill", title: "Wejdź w Ustawienia",
                 text: "Teraz dotknij zakładki „Ustawienia” (albo „Dalej”)."),
        TourStep(tab: .settings, icon: "paintbrush.fill", title: "Ustawienia",
                 text: "Tu zmienisz tło aplikacji (okładka piosenki, kolor albo własne zdjęcie), kolory tekstów, cenzurę przekleństw, tłumaczenie i rozmiar tekstu. Stąd też włączysz ten przewodnik jeszcze raz.",
                 bottom: true),
        TourStep(tab: .home, icon: "checkmark.circle.fill", title: "Gotowe!",
                 text: "Znasz już całą aplikację. Wyszukaj pierwszą piosenkę i miłego słuchania!")
    ]
}

// MARK: - Nakładka

/// Przyciemnia ekran, zostawia "okno" na wskazany element, rysuje strzałkę i dymek z opisem.
struct TourOverlay: View {
    @Environment(\.ink) private var ink
    let step: TourStep
    let index: Int
    let count: Int
    /// Miejsce wskazanego elementu na ekranie (nil = nie ma go teraz na ekranie: sam dymek).
    let target: CGRect?
    let size: CGSize
    let onNext: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void

    private var hole: CGRect? { target.map { $0.insetBy(dx: -8, dy: -8) } }
    private var holeRadius: CGFloat { min((hole?.height ?? 0) / 2, 34) }
    /// Element jest w górnej połowie ekranu: dymek pod nim. W dolnej: dymek nad nim.
    private var cardBelow: Bool { (hole?.midY ?? 0) < size.height * 0.5 }
    private var isLast: Bool { index == count - 1 }

    var body: some View {
        ZStack {
            // Przyciemnienie z oknem. Zasłania i blokuje wszystko pod spodem.
            SpotlightShape(hole: hole ?? CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0),
                           radius: holeRadius)
                .fill(Color.black.opacity(0.66), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture { }

            if let hole = hole {
                // Obwódka okna. Dotknięcie wskazanego elementu = następny krok.
                RoundedRectangle(cornerRadius: holeRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.95), lineWidth: 2)
                    .frame(width: hole.width, height: hole.height)
                    .contentShape(Rectangle())
                    .onTapGesture { advance() }
                    .position(x: hole.midX, y: hole.midY)

                TourArrow(pointsUp: cardBelow)
                    .position(x: min(max(hole.midX, 44), size.width - 44),
                              y: cardBelow ? hole.maxY + 28 : hole.minY - 28)
            }

            placedCard
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: index)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: target)
    }

    private func advance() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onNext()
    }

    /// Dymek ustawiony pod / nad wskazanym elementem albo na środku (na dole, gdy krok tego chce).
    private var placedCard: some View {
        VStack(spacing: 0) {
            if let hole = hole {
                if cardBelow {
                    Spacer().frame(height: max(hole.maxY + 58, 0))
                    card
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    card
                    Spacer().frame(height: max(size.height - hole.minY + 58, 0))
                }
            } else if step.bottom {
                Spacer(minLength: 0)
                card
                Spacer().frame(height: 130)
            } else {
                Spacer(minLength: 0)
                card
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: size.width, height: size.height)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: step.icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(ink)
                    .frame(width: 38, height: 38)
                    .background(ink.opacity(0.14), in: Circle())
                Text(step.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text("\(index + 1) / \(count)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ink.opacity(0.5))
            }

            if step.demo {
                TourLyricsDemo()
            }

            Text(step.text)
                .font(.system(size: 16))
                .foregroundStyle(ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if !isLast {
                    Button(action: onSkip) {
                        Text("Pomiń")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.55))
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if index > 0 {
                    Button(action: onBack) {
                        Text("Wstecz")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ink)
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(ink.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.94))
                }
                Button(action: advance) {
                    Text(isLast ? "Zaczynamy!" : "Dalej")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .padding(.horizontal, 22)
                        .frame(height: 44)
                        .background(ink, in: Capsule())
                }
                .buttonStyle(PressScaleStyle(scale: 0.94))
            }
        }
        .padding(18)
        .frame(maxWidth: 400)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(ink.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        .id(index)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// Przyciemnienie całego ekranu z zaokrąglonym oknem (okno płynnie przesuwa się między krokami).
private struct SpotlightShape: Shape {
    var hole: CGRect
    var radius: CGFloat

    var animatableData: AnimatablePair<CGRect.AnimatableData, CGFloat> {
        get { AnimatablePair(hole.animatableData, radius) }
        set {
            hole.animatableData = newValue.first
            radius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if hole.width > 1, hole.height > 1 {
            let r = max(0, min(radius, hole.width / 2, hole.height / 2))
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: r, height: r), style: .continuous)
        }
        return path
    }
}

/// Podskakująca strzałka wskazująca element.
private struct TourArrow: View {
    let pointsUp: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Image(systemName: pointsUp ? "arrow.up" : "arrow.down")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.6), radius: 6)
                .offset(y: CGFloat(5 * sin(t * 5)))
        }
        .frame(width: 44, height: 44)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Małe demo tekstu piosenki: podświetlona linijka przechodzi co chwilę na następną.
private struct TourLyricsDemo: View {
    @Environment(\.ink) private var ink
    @State private var active = 0
    private let lines = ["Ta linijka już była", "Ta jest właśnie śpiewana", "A ta będzie następna", "I jeszcze jedna"]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(lines.indices, id: \.self) { i in
                Text(lines[i])
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(ink.opacity(i == active ? 1 : 0.32))
                    .scaleEffect(i == active ? 1 : 0.95, anchor: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                if Task.isCancelled { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    active = (active + 1) % lines.count
                }
            }
        }
        .accessibilityHidden(true)
    }
}
