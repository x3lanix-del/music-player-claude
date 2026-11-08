import SwiftUI

// MARK: - Dane jednej linijki (liczone raz, nie co klatkę)

/// Linijka tekstu z gotowymi czasami zapalania każdej litery. Powstaje raz po załadowaniu tekstu,
/// więc podczas odtwarzania nic nie jest liczone od nowa poza samą aktywną linijką.
struct LyricRow: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
    let chars: [Character]
    /// Czas w tekście (s), od którego litera zaczyna się zapalać.
    let starts: [Double]
    /// Ile sekund trwa zapalanie litery (miękka krawędź fali).
    let fades: [Double]

    static func == (a: LyricRow, b: LyricRow) -> Bool {
        a.id == b.id && a.time == b.time && a.text == b.text
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
                            fades.append(max(0.22, dur / Double(n) * 2.6))
                        }
                    }
                    // Białe znaki na brzegach tylko psują układ.
                    while let f = chars.first, f.isWhitespace { chars.removeFirst(); starts.removeFirst(); fades.removeFirst() }
                    while let l = chars.last, l.isWhitespace { chars.removeLast(); starts.removeLast(); fades.removeLast() }
                }
            }

            // 2) Tylko czas linijki: fala rozłożona równo po literach aż do następnej linijki.
            if chars.isEmpty {
                let cs = Array(shown.trimmingCharacters(in: .whitespacesAndNewlines))
                let n = cs.count
                if n > 0 {
                    let span = min(max((nextTime - line.time) * 0.92, 0.8), 9)
                    for (k, c) in cs.enumerated() {
                        chars.append(c)
                        starts.append(line.time + span * Double(k) / Double(n))
                        fades.append(max(0.28, span / Double(n) * 3))
                    }
                }
            }
            rows.append(LyricRow(id: line.id, time: line.time, text: String(chars), chars: chars, starts: starts, fades: fades))
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

// MARK: - Wiersz listy

private struct LyricRowView: View, Equatable {
    @Environment(\.lyricsInk) private var lyricsInk
    let row: LyricRow
    /// 0 = aktywna, 1 = sąsiednia, 2 = dalsza.
    let level: Int
    let fontSize: Double
    let translation: String?
    let seekable: Bool
    let engine: PlayerEngine
    let lyrics: LyricsController
    let onTap: () -> Void

    static func == (l: LyricRowView, r: LyricRowView) -> Bool {
        l.row == r.row && l.level == r.level && l.fontSize == r.fontSize
            && l.translation == r.translation && l.seekable == r.seekable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if row.chars.isEmpty {
                // Pusta linijka (przerwa instrumentalna): sam odstęp, bez kropek.
                Color.clear.frame(maxWidth: .infinity).frame(height: fontSize * 0.5)
            } else {
                // Linijka po linijce: aktywna świeci w całości, reszta jest przygaszona.
                Text(row.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(lyricsInk.opacity(level == 0 ? 1 : 0.38))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let tr = translation, !tr.isEmpty, !row.chars.isEmpty, tr.lowercased() != row.text.lowercased() {
                Text(tr)
                    .font(.system(size: max(15, fontSize * 0.5), weight: .semibold))
                    .foregroundStyle(lyricsInk.opacity(0.75))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scaleEffect(level == 0 ? 1 : 0.95, anchor: .leading)
        .opacity(level == 0 ? 1 : (level == 1 ? 0.6 : 0.42))
        .animation(.easeInOut(duration: 0.45), value: level)
        .contentShape(Rectangle())
        .onTapGesture { if seekable { onTap() } }
    }
}

// MARK: - Ekran tekstu

/// Teksty w stylu Apple Music: duże linijki, aktywna jasna w całości, reszta przygaszona.
struct LyricsView: View {
    @Environment(\.lyricsInk) private var lyricsInk
    @ObservedObject var lyrics: LyricsController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine

    private let anchor = UnitPoint(x: 0, y: 0.22)
    @State private var translations: [String] = []
    @State private var cache = LyricRowCache()

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
            VStack { Spacer(); ProgressView().tint(lyricsInk); Spacer() }
                .frame(maxWidth: .infinity)
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
            Spacer().frame(height: 30)
        }
    }

    private func message(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 34, weight: .semibold))
            Text(text).font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
            Spacer()
        }
        .foregroundStyle(lyricsInk.opacity(0.7))
        .frame(maxWidth: .infinity)
    }

    private func level(of index: Int) -> Int {
        let d = abs(index - lyrics.activeIndex)
        return d == 0 ? 0 : (d == 1 ? 1 : 2)
    }

    private var synced: some View {
        let rows = cache.rows(revision: lyrics.revision, censor: settings.data.censorProfanity, lines: lyrics.lines)
        let seekable = !engine.isRadio
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    Spacer().frame(height: 30)
                    ForEach(rows) { row in
                        LyricRowView(row: row,
                                     level: level(of: row.id),
                                     fontSize: settings.data.lyricsFontSize,
                                     translation: translations.indices.contains(row.id) ? translations[row.id] : nil,
                                     seekable: seekable,
                                     engine: engine,
                                     lyrics: lyrics) {
                            engine.seek(to: max(0, lyrics.playerTime(forLyric: row.time)))
                        }
                        .equatable()
                        .id(row.id)
                    }
                    Spacer().frame(height: 280)
                }
            }
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.10),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: lyrics.activeIndex) { _, newIndex in
                guard newIndex >= 0 else { return }
                // Jeden spokojny ruch w górę (bez sprężynowania); linie tylko zmieniają jasność.
                withAnimation(.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.55)) {
                    proxy.scrollTo(newIndex, anchor: anchor)
                }
            }
            .task(id: translationKey) { await loadTranslations() }
            .onAppear {
                if lyrics.activeIndex >= 0 { proxy.scrollTo(lyrics.activeIndex, anchor: anchor) }
            }
        }
        .id(lyrics.revision)
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
