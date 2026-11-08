import SwiftUI

// MARK: - Dane jednej linijki (liczone raz, nie co klatkę)

/// Linijka tekstu z gotowymi czasami zapalania każdej litery. Powstaje raz po załadowaniu tekstu,
/// więc podczas odtwarzania nic nie jest liczone od nowa poza samą aktywną linijką.
struct LyricRow: Identifiable, Equatable {
    let id: Int
    let time: Double
    /// Początek następnej linijki (koniec przerwy instrumentalnej).
    let end: Double
    let text: String
    let chars: [Character]
    /// Czas w tekście (s), od którego litera zaczyna się zapalać.
    let starts: [Double]
    /// Ile sekund trwa zapalanie litery (miękka krawędź fali).
    let fades: [Double]
    /// True = czasy liter pochodzą z czasów słów/sylab (prawdziwe karaoke), false = fala rozłożona na linijkę.
    let wordSynced: Bool

    static func == (a: LyricRow, b: LyricRow) -> Bool {
        a.id == b.id && a.time == b.time && a.end == b.end && a.text == b.text && a.wordSynced == b.wordSynced
    }

    private static func normalized(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Cenzura liczona na całej linijce (wulgaryzm może być rozbity na sylaby), potem pocięta z powrotem na kawałki.
    private static func censoredRuns(_ words: [LyricRun], censor: Bool) -> [LyricRun] {
        guard censor, !words.isEmpty else { return words }
        let joined = words.map { $0.text }.joined()
        let censored = Array(Profanity.censor(joined))
        guard censored.count == joined.count else { return words }
        var out = words
        var pos = 0
        for k in out.indices {
            let n = words[k].text.count
            out[k].text = String(censored[pos..<(pos + n)])
            pos += n
        }
        return out
    }

    static func build(lines: [LyricLine], censor: Bool) -> [LyricRow] {
        var rows: [LyricRow] = []
        rows.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {
            let shown = censor ? Profanity.censor(line.text) : line.text
            let nextTime = i + 1 < lines.count ? lines[i + 1].time : line.time + 4
            var chars: [Character] = []
            var starts: [Double] = []
            var fades: [Double] = []
            var wordSynced = false

            // 1) Źródło z czasami słów/sylab: każda litera zapala się dokładnie wtedy, gdy jest śpiewana.
            if !line.words.isEmpty {
                let runs = censoredRuns(line.words, censor: censor)
                let joined = runs.map { $0.text }.joined()
                if normalized(joined) == normalized(shown), !joined.isEmpty {
                    for run in runs {
                        let cs = Array(run.text)
                        let n = cs.count
                        if n == 0 { continue }
                        let dur = max(run.end - run.start, 0.08)
                        for (k, c) in cs.enumerated() {
                            chars.append(c)
                            starts.append(run.start + dur * Double(k) / Double(n))
                            fades.append(min(max(0.18, dur / Double(n) * 2.4), 0.9))
                        }
                    }
                    // Białe znaki na brzegach tylko psują układ.
                    while let f = chars.first, f.isWhitespace { chars.removeFirst(); starts.removeFirst(); fades.removeFirst() }
                    while let l = chars.last, l.isWhitespace { chars.removeLast(); starts.removeLast(); fades.removeLast() }
                    wordSynced = !chars.isEmpty
                }
            }

            // 2) Tylko czas linijki: fala po literach w tempie zwykłego śpiewu (ok. 12 liter na sekundę),
            //    ale nigdy dłużej niż do następnej linijki - dzięki temu nie "wlecze się" za wokalem przy długich przerwach.
            if chars.isEmpty {
                let cs = Array(shown.trimmingCharacters(in: .whitespacesAndNewlines))
                let n = cs.count
                if n > 0 {
                    let gap = max(nextTime - line.time, 0.3)
                    let sung = Double(n) * 0.085 + 0.4
                    let span = min(max(min(gap * 0.92, sung), 0.6), 9)
                    for (k, c) in cs.enumerated() {
                        chars.append(c)
                        starts.append(line.time + span * Double(k) / Double(n))
                        fades.append(max(0.28, span / Double(n) * 3))
                    }
                }
            }
            rows.append(LyricRow(id: line.id, time: line.time, end: nextTime, text: String(chars), chars: chars,
                                 starts: starts, fades: fades, wordSynced: wordSynced))
        }
        return rows
    }
}

/// Pamięć gotowych linijek (zwykła klasa, żeby wypełnianie jej w trakcie rysowania niczego nie odświeżało).
final class LyricRowCache {
    private var key = ""
    private var rows: [LyricRow] = []

    func rows(revision: Int, censor: Bool, lines: [LyricLine]) -> [LyricRow] {
        let k = "\(revision)|\(censor)|\(lines.count)"
        if k != key {
            rows = LyricRow.build(lines: lines, censor: censor)
            key = k
        }
        return rows
    }
}

// MARK: - Karaoke (iOS 18+): litery zapalają się dokładnie wtedy, gdy są śpiewane

#if compiler(>=6.0)

/// Czas zapalania jednej litery, przyczepiony do jej kawałka tekstu.
@available(iOS 18.0, *)
struct KaraokeGlyph: TextAttribute, Hashable {
    let start: Double
    let fade: Double
}

/// Rysuje aktywną linijkę: zaśpiewane litery są jasne, kolejne przygaszone, a granica przesuwa się miękką falą
/// (z lekkim uniesieniem litery w chwili zaśpiewania). Układ tekstu się nie zmienia - zmienia się tylko rysowanie,
/// więc nawet 120 klatek na sekundę nic nie kosztuje.
@available(iOS 18.0, *)
struct KaraokeRenderer: TextRenderer {
    var time: Double
    /// Jasność jeszcze niezaśpiewanych liter (0...1).
    var dim: Double
    /// Jak wysoko (pt) podskakuje litera w chwili zaśpiewania.
    var lift: CGFloat

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let g = run[KaraokeGlyph.self] else {
                    ctx.draw(run)
                    continue
                }
                let raw = (time - g.start) / max(g.fade, 0.01)
                let p = min(max(raw, 0), 1)
                let eased = p * p * (3 - 2 * p)
                var c = ctx
                c.opacity = dim + (1 - dim) * eased
                if lift > 0, p > 0, p < 1 {
                    c.translateBy(x: 0, y: -lift * CGFloat(sin(Double.pi * p)))
                }
                c.draw(run)
            }
        }
    }
}

@available(iOS 18.0, *)
enum KaraokeText {
    /// Każda litera to osobny kawałek tekstu z własnym czasem (zawijanie linijek działa jak w zwykłym tekście).
    static func make(_ row: LyricRow) -> Text {
        var text = Text(verbatim: "")
        for k in row.chars.indices {
            let piece = Text(verbatim: String(row.chars[k]))
                .customAttribute(KaraokeGlyph(start: row.starts[k], fade: row.fades[k]))
            text = text + piece
        }
        return text
    }
}

@available(iOS 18.0, *)
private struct KaraokeLine: View {
    let row: LyricRow
    let fontSize: Double
    let ink: Color
    let playing: Bool
    let engine: PlayerEngine
    let lyrics: LyricsController

    var body: some View {
        let text = KaraokeText.make(row)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(ink)
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !playing)) { _ in
            text
                .textRenderer(KaraokeRenderer(time: lyrics.lyricTime(forPlayer: engine.livePlaybackTime()),
                                              dim: 0.34, lift: CGFloat(fontSize) * 0.06))
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif

// MARK: - Przerwa instrumentalna: trzy kropki, które zapalają się po kolei i "oddychają"

private struct InterludeDots: View {
    let row: LyricRow
    let fontSize: Double
    let ink: Color
    let playing: Bool
    let engine: PlayerEngine
    let lyrics: LyricsController

    var body: some View {
        let dot = max(9, fontSize * 0.3)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { _ in
            let t = lyrics.lyricTime(forPlayer: engine.livePlaybackTime())
            let length = max(row.end - row.time, 0.5)
            let p = min(max((t - row.time) / length, 0), 1)
            // Pod koniec przerwy kropki znikają (zaraz wraca śpiew).
            let outro = p > 0.9 ? max(0, 1 - (p - 0.9) / 0.1) : 1
            let breath = 1 + 0.07 * sin(t * 2.4)
            HStack(spacing: dot * 0.55) {
                ForEach(0..<3, id: \.self) { i in
                    let local = min(max(p * 3 - Double(i), 0), 1)
                    Circle()
                        .fill(ink)
                        .frame(width: dot, height: dot)
                        .opacity(0.28 + 0.72 * local)
                        .scaleEffect(0.82 + 0.18 * local)
                }
            }
            .scaleEffect(breath * outro, anchor: .leading)
            .opacity(outro)
            .frame(maxWidth: .infinity, minHeight: dot * 2.2, alignment: .leading)
        }
    }
}

// MARK: - Wiersz listy

private struct LyricRowView: View, Equatable {
    @Environment(\.lyricsInk) private var lyricsInk
    let row: LyricRow
    /// 0 = aktywna, 1 = sąsiednia, 2 = dalsza.
    let level: Int
    let fontSize: Double
    let translation: String?
    let seekable: Bool
    /// Rozmycie dalszych linijek (wyłączone, gdy użytkownik sam przewija tekst).
    let blur: Bool
    /// Fala liter w aktywnej linijce.
    let karaoke: Bool
    let playing: Bool
    let engine: PlayerEngine
    let lyrics: LyricsController
    let onTap: () -> Void

    static func == (l: LyricRowView, r: LyricRowView) -> Bool {
        l.row == r.row && l.level == r.level && l.fontSize == r.fontSize
            && l.translation == r.translation && l.seekable == r.seekable
            && l.blur == r.blur && l.karaoke == r.karaoke
            && (l.level != 0 || l.playing == r.playing)
    }

    /// Przerwa dość długa, żeby pokazać kropki (krótkie puste linijki to tylko odstęp).
    private var isInterlude: Bool { row.chars.isEmpty && row.end - row.time >= 2.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if row.chars.isEmpty {
                if level == 0 && isInterlude {
                    InterludeDots(row: row, fontSize: fontSize, ink: lyricsInk, playing: playing,
                                  engine: engine, lyrics: lyrics)
                        .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
                } else {
                    // Pusta linijka (przerwa instrumentalna): sam odstęp.
                    Color.clear.frame(maxWidth: .infinity).frame(height: fontSize * 0.5)
                }
            } else {
                lineText
            }
            if let tr = translation, !tr.isEmpty, !row.chars.isEmpty, tr.lowercased() != row.text.lowercased() {
                Text(tr)
                    .font(.system(size: max(15, fontSize * 0.5), weight: .semibold))
                    .foregroundStyle(lyricsInk.opacity(level == 0 ? 0.85 : 0.6))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scaleEffect(level == 0 ? 1 : 0.96, anchor: .leading)
        .opacity(level == 0 ? 1 : (level == 1 ? 0.62 : 0.42))
        .blur(radius: blur ? (level == 0 ? 0 : (level == 1 ? 0.9 : 2.2)) : 0)
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: level)
        .animation(.easeInOut(duration: 0.3), value: blur)
        .contentShape(Rectangle())
        .onTapGesture {
            guard seekable else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        }
    }

    private var plainLine: some View {
        Text(row.text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(lyricsInk.opacity(level == 0 ? 1 : 0.38))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var lineText: some View {
        #if compiler(>=6.0)
        if level == 0 && karaoke {
            if #available(iOS 18.0, *) {
                KaraokeLine(row: row, fontSize: fontSize, ink: lyricsInk, playing: playing, engine: engine, lyrics: lyrics)
            } else {
                plainLine
            }
        } else {
            plainLine
        }
        #else
        plainLine
        #endif
    }
}

// MARK: - Wykrywanie przewijania palcem

/// Wywołuje `onBegin`, gdy użytkownik zaczyna przewijać tekst palcem, a `onEnd`, gdy przestaje.
private struct UserScrollWatcher: ViewModifier {
    let onBegin: () -> Void
    let onEnd: () -> Void

    func body(content: Content) -> some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting: onBegin()
                case .idle: onEnd()
                default: break
                }
            }
        } else {
            dragFallback(content)
        }
        #else
        dragFallback(content)
        #endif
    }

    private func dragFallback(_ content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { _ in onBegin() }
                .onEnded { _ in onEnd() }
        )
    }
}

// MARK: - Ładowanie: migające "linijki" zamiast kółka

private struct LyricsSkeleton: View {
    let ink: Color
    let fontSize: Double
    @State private var pulse = false
    private let widths: [CGFloat] = [0.82, 0.64, 0.9, 0.55, 0.74, 0.6]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 24) {
                Spacer().frame(height: 24)
                ForEach(widths.indices, id: \.self) { i in
                    Capsule()
                        .fill(ink.opacity(pulse ? 0.2 : 0.07))
                        .frame(width: geo.size.width * widths[i], height: max(18, fontSize * 0.62))
                        .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(Double(i) * 0.11),
                                   value: pulse)
                }
                HStack(spacing: 8) {
                    ProgressView().tint(ink.opacity(0.7)).controlSize(.small)
                    Text("Szukam tekstu…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.6))
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
        }
        .onAppear { pulse = true }
        .accessibilityLabel("Szukam tekstu")
    }
}

// MARK: - Ekran tekstu

/// Teksty w stylu Apple Music: duże linijki, aktywna zapala się litera po literze, reszta przygaszona i rozmyta.
struct LyricsView: View {
    @Environment(\.lyricsInk) private var lyricsInk
    @ObservedObject var lyrics: LyricsController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine

    private let anchor = UnitPoint(x: 0, y: 0.22)
    @State private var translations: [String] = []
    @State private var cache = LyricRowCache()
    /// Użytkownik przegląda tekst palcem: bez automatycznego przewijania i bez rozmycia.
    @State private var browsing = false
    @State private var resumeTask: Task<Void, Never>? = nil

    private var translationKey: String {
        "\(lyrics.revision)|\(settings.data.translateLyrics)|\(settings.data.translateTarget)|\(settings.data.censorProfanity)"
    }

    private func loadTranslations() async {
        guard settings.data.translateLyrics, !lyrics.lines.isEmpty, let id = engine.currentTrack?.id else {
            translations = []
            return
        }
        let censor = settings.data.censorProfanity
        let out = await LyricsTranslator.shared.translate(lyrics.lines.map { $0.text }, to: settings.data.translateTarget, key: id)
        if Task.isCancelled { return }
        translations = (out ?? []).map { censor ? Profanity.censor($0) : $0 }
    }

    var body: some View {
        ZStack {
            content
                .id(lyrics.revision)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
        .animation(.easeInOut(duration: 0.35), value: lyrics.revision)
    }

    @ViewBuilder private var content: some View {
        switch lyrics.phase {
        case .synced:
            // Radio bez znanej pozycji w piosence: sam tekst (animacja ruszy, gdy pozycja się ustali).
            if engine.isRadio && !engine.radioPositionKnown {
                plainView(lyrics.lines.map { $0.text }.filter { !$0.isEmpty }.joined(separator: "\n"))
            } else {
                synced
            }
        case .plain:
            plainView(lyrics.plainText)
        case .idle, .loading:
            LyricsSkeleton(ink: lyricsInk, fontSize: settings.data.lyricsFontSize)
        case .instrumental:
            message("Utwór instrumentalny", "music.note")
        case .notFound:
            message("Nie znaleziono tekstu", "text.quote")
        case .offline:
            message("Brak internetu. Tekst pojawi się sam, gdy połączenie wróci", "wifi.slash")
        }
    }

    private func plainView(_ text: String) -> some View {
        ScrollView(showsIndicators: false) {
            Text(settings.data.censorProfanity ? Profanity.censor(text) : text)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(lyricsInk.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
            sourceFooter
            Spacer().frame(height: 30)
        }
    }

    private func message(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .symbolEffect(.pulse, isActive: lyrics.phase == .offline)
            Text(text).font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
            if lyrics.phase == .notFound, let t = engine.currentTrack, !t.isRadio {
                Button {
                    engine.refreshLyrics()
                } label: {
                    Label("Szukaj jeszcze raz", systemImage: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glass(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            Spacer()
        }
        .foregroundStyle(lyricsInk.opacity(0.7))
        .frame(maxWidth: .infinity)
    }

    /// Skąd jest tekst (jak "Tekst: …" na końcu tekstu w Apple Music).
    @ViewBuilder private var sourceFooter: some View {
        if let source = lyrics.current?.source, !source.isEmpty {
            let kind = lyrics.current?.hasWords == true ? " · słowo po słowie" : ""
            Text("Tekst: \(source)\(kind)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(lyricsInk.opacity(0.42))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Pusta linijka "intro" od początku piosenki do pierwszej śpiewanej linijki (gdy źródło jej nie ma).
    private func introRow(_ rows: [LyricRow]) -> LyricRow? {
        guard let first = rows.first, !first.chars.isEmpty, first.time >= 3 else { return nil }
        return LyricRow(id: -1, time: 0, end: first.time, text: "", chars: [], starts: [], fades: [], wordSynced: false)
    }

    private func level(of index: Int) -> Int {
        let d = abs(index - lyrics.activeIndex)
        return d == 0 ? 0 : (d == 1 ? 1 : 2)
    }

    private func beginBrowsing() {
        resumeTask?.cancel()
        resumeTask = nil
        if !browsing { browsing = true }
    }

    /// Po kilku sekundach bez dotykania tekst sam wraca do śpiewanej linijki.
    private func scheduleResume() {
        guard browsing else { return }
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if Task.isCancelled { return }
            browsing = false
        }
    }

    private var synced: some View {
        let rows = cache.rows(revision: lyrics.revision, censor: settings.data.censorProfanity, lines: lyrics.lines)
        let seekable = !engine.isRadio
        let blur = settings.data.blurInactiveLyrics && !browsing
        let karaokeAll = settings.data.karaokeLyrics
        let karaokeLines = settings.data.karaokeLineSync
        let playing = engine.isPlaying
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    Spacer().frame(height: 30)
                    if let intro = introRow(rows) {
                        // Intro bez śpiewu: kropki odliczają do pierwszej linijki.
                        LyricRowView(row: intro,
                                     level: lyrics.activeIndex < 0 && !browsing ? 0 : 2,
                                     fontSize: settings.data.lyricsFontSize,
                                     translation: nil,
                                     seekable: seekable,
                                     blur: blur,
                                     karaoke: false,
                                     playing: playing,
                                     engine: engine,
                                     lyrics: lyrics) {
                            engine.seek(to: 0)
                        }
                        .equatable()
                        .id(intro.id)
                    }
                    ForEach(rows) { row in
                        LyricRowView(row: row,
                                     level: browsing ? (row.id == lyrics.activeIndex ? 0 : 1) : level(of: row.id),
                                     fontSize: settings.data.lyricsFontSize,
                                     translation: translations.indices.contains(row.id) ? translations[row.id] : nil,
                                     seekable: seekable,
                                     blur: blur,
                                     karaoke: karaokeAll && (row.wordSynced || karaokeLines),
                                     playing: playing,
                                     engine: engine,
                                     lyrics: lyrics) {
                            resumeTask?.cancel()
                            browsing = false
                            engine.seek(to: max(0, lyrics.playerTime(forLyric: row.time)))
                        }
                        .equatable()
                        .id(row.id)
                    }
                    sourceFooter.padding(.top, 10)
                    Spacer().frame(height: 280)
                }
            }
            .modifier(UserScrollWatcher(onBegin: { beginBrowsing() }, onEnd: { scheduleResume() }))
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.10),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
            .overlay(alignment: .bottom) {
                if browsing && lyrics.activeIndex >= 0 {
                    Button {
                        resumeTask?.cancel()
                        browsing = false
                    } label: {
                        Label("Wróć do śpiewanej linijki", systemImage: "arrow.down.to.line")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(lyricsInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .glass(Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if lyrics.isUpgrading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).tint(lyricsInk)
                        Text("Szukam wersji słowo po słowie")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(lyricsInk.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glass(Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: browsing)
            .animation(.easeInOut(duration: 0.3), value: lyrics.isUpgrading)
            .onChange(of: lyrics.activeIndex) { _, newIndex in
                guard newIndex >= 0, !browsing else { return }
                // Jeden spokojny ruch w górę (bez sprężynowania); linie tylko zmieniają jasność.
                withAnimation(.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.55)) {
                    proxy.scrollTo(newIndex, anchor: anchor)
                }
            }
            .onChange(of: browsing) { _, isBrowsing in
                guard !isBrowsing, lyrics.activeIndex >= 0 else { return }
                withAnimation(.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.7)) {
                    proxy.scrollTo(lyrics.activeIndex, anchor: anchor)
                }
            }
            .task(id: translationKey) { await loadTranslations() }
            .onAppear {
                if lyrics.activeIndex >= 0 { proxy.scrollTo(lyrics.activeIndex, anchor: anchor) }
            }
            .onDisappear { resumeTask?.cancel() }
        }
    }
}

// MARK: - Picker of another lyrics version

struct LyricsPickerSheet: View {
    @EnvironmentObject var engine: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LyricsCandidate] = []
    @State private var sourceResults: [LyricsCandidate] = []
    @State private var loadingSources = false
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Wykonawca i tytuł", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await run() } }
                } footer: {
                    Text("Wybierz wersję o takim samym czasie trwania jak piosenka (zielony czas). Inna wersja = inny rytm tekstu.")
                }
                if loadingSources || !sourceResults.isEmpty {
                    Section("Wersje ze wszystkich źródeł") {
                        if loadingSources && sourceResults.isEmpty {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        }
                        ForEach(sourceResults, id: \.uid) { c in
                            Button {
                                engine.chooseLyrics(c)
                                dismiss()
                            } label: { row(c) }
                        }
                    }
                }
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(results, id: \.uid) { c in
                    Button {
                        engine.chooseLyrics(c)
                        dismiss()
                    } label: { row(c) }
                }
            }
            .navigationTitle("Wersja tekstu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Gotowe") { dismiss() } } }
            .task {
                if let t = engine.currentTrack, let g = TitleCleaner.guesses(title: t.title, channel: t.artist).first {
                    query = "\(g.artist) \(g.title)"
                }
                Task { await loadSources() }
                await run()
            }
        }
        .presentationDetents([.large])
    }

    private func row(_ c: LyricsCandidate) -> some View {
        let video = engine.currentTrack?.duration ?? 0
        let isCurrent = engine.lyrics.current?.uid == c.uid
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title.isEmpty ? "—" : c.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                Text(c.artist).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(c.source ?? "")
                    if let d = c.duration, d > 0 {
                        Text("· \(Fmt.time(d))" + (video > 0 ? " (film \(Fmt.time(video)))" : ""))
                            .foregroundStyle(video > 0 && abs(d - video) <= 2 ? Color.green : Color.orange)
                    }
                    Text(c.hasWords ? "· słowo po słowie" : (c.hasSynced ? "· z synchronizacją" : "· zwykły tekst"))
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isCurrent { Image(systemName: "checkmark.circle.fill") }
        }
        .contentShape(Rectangle())
    }

    private func loadSources() async {
        guard let track = engine.currentTrack else { return }
        loadingSources = true
        let list = await LyricsService.shared.providerCandidates(for: track)
        sourceResults = list.sorted { ($0.hasWords ? 0 : 1) < ($1.hasWords ? 0 : 1) }
        loadingSources = false
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loading = true
        let list = await LyricsService.shared.search(query: q)
        let video = engine.currentTrack?.duration ?? 0
        // Z synchronizacją i najbliższym czasem trwania na górze.
        results = list.sorted {
            if $0.hasSynced != $1.hasSynced { return $0.hasSynced }
            guard video > 0 else { return false }
            return abs(($0.duration ?? 9999) - video) < abs(($1.duration ?? 9999) - video)
        }
        loading = false
    }
}
