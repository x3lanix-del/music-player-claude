## 1.34.0 - tło dokładnie jak w repozytorium „Apple Music Background”
- Tło zrobione techniką z repozytorium frigopedro/Apple-Music-Background: z okładki 5 dominujących kolorów,
  siatka pól (5 x 7), każde pole losowo jednym z tych kolorów, a na wierzchu bardzo mocne rozmycie (ok. 90 pt)
  i czarna warstwa 30% - efekt matowego szkła jak w Apple Music. Układ pól jest stały dla danej piosenki.
- Żeby tło żyło jak w Apple Music: co kilka sekund kilka pól płynnie zmienia kolor (tempo: Ustawienia →
  Tempo animacji tła). Przy zmianie piosenki kolory płynnie przechodzą w nowe.
- Działa tak samo na iOS 17 i 18+. Rozmycie liczone w 1/8 rozdzielczości, więc prawie nie obciąża telefonu.

## 1.33.0 - tło z siatki kolorów (jak w Apple Music)
- Nowe tło (iOS 18+): z okładki wybieranych jest 5 dominujących kolorów (także szarości i czerni - w takich
  proporcjach, w jakich są na okładce), które trafiają losowo - ale dla danej piosenki zawsze tak samo - na
  siatkę 4x4. Kolory płynnie przechodzą w siebie (MeshGradient), a punkty siatki powoli falują, więc plamy
  kolorów płyną po ekranie. Przy zmianie piosenki kolory płynnie przechodzą w nowe. Na iOS 17 zostaje
  poprzednie tło (obracające się kopie okładki).
- Przyciski odtwarzania znowu bez kolorów z okładki: pasek postępu, przycisk play i pasek w mini-odtwarzaczu
  są w zwykłym kolorze (bez kolorowej poświaty).

## 1.32.0 - tło jak w Apple Music
- Tło zrobione tak, jak robi to Apple Music: pięć kopii **ostrej** okładki (jedna wielka pod spodem, cztery mniejsze
  w rogach) krąży i obraca się w różnych tempach i kierunkach, a **dopiero potem** całość jest mocno rozmyta
  i lekko nasycona. Wcześniej okładka była rozmywana przed obracaniem, więc zostawała jednolita plama i ruchu
  nie było widać. Teraz po ekranie płyną prawdziwe kolory i kształty okładki.
- Kolory tła są dokładnie z okładki (bez „poprawiania” barw): szara okładka z odrobiną niebieskiego nie robi się
  już niebieska.
- Kolor klimatu (poświata, pasek postępu, świecący tekst) tylko wtedy, gdy jakiś kolor naprawdę dominuje na okładce;
  mały kolorowy element na szarej okładce nie barwi już aplikacji.
- Rozmycie liczone w 1/6 rozdzielczości, więc mimo ruchu tło prawie nie obciąża telefonu.

## 1.31.0 - więcej klimatu
- **Kolory tła pasują do okładki:** pastelowe okładki (np. jasny róż, błękit) nie wychodzą już na biało / szaro -
  tło dostaje tyle nasycenia, żeby było w kolorze okładki; szare okładki dalej są szare. Jasne okładki są
  przyciemniane delikatniej, żeby kolor był widać.
- **Kolor klimatu piosenki:** z okładki wybierany jest jej najbardziej wyrazisty kolor. W nim świeci duża okładka
  (poświata), pasek postępu, śpiewana linijka tekstu, pulsująca poświata pod przyciskiem play i pasek
  w mini-odtwarzaczu. Przy zmianie piosenki kolory płynnie się zmieniają. (Własny kolor akcentu z Ustawień
  ma pierwszeństwo.)
- **Polubienie:** serduszka wylatują w górę + wibracja „udało się”.
- **Wibracje:** play/pauza, następna/poprzednia, start piosenki z listy.
- **Główna:** przycisk „Zaskocz mnie” (losowy miks 30 piosenek z ostatnio granych, ulubionych i list na czasie,
  z turlającą się kostką), powitanie w kolorze grającej piosenki, złoty / srebrny / brązowy numer dla podium
  „Na czasie w Polsce” z koroną dla numeru 1.
- Usunięty testowy workflow „Runner check”.

## 1.30.0
- **Nowa zakładka Główna** (pierwsza na pasku): „Ostatnio grane”, „Na czasie w Polsce” (top 20 teledysków
  muzycznych z YouTube, przez YouTube Data API v3) i „Na czasie na świecie”. Listy zapisują się na dysku (są od razu,
  też bez internetu) i odświeżają co kilka godzin albo po przeciągnięciu w dół. Przytrzymaj okładkę: zagraj jako
  następną, do kolejki, do playlisty.
- **Piosenki startują od razu:** adresy strumieni pierwszych piosenek z wyników wyszukiwania, playlisty i zakładki
  Główna są pobierane z wyprzedzeniem, więc po dotknięciu nie trzeba czekać na YouTube.
- **Ze strumienia na plik bez przerwy:** piosenka gra najpierw z internetu, a w tle pobiera się na dysk. Gdy się
  pobierze, odtwarzacz przechodzi na plik (bez internetu) w chwili, gdy tego nie słychać: przy pauzie, przy
  przewijaniu, gdy strumień się zatnie albo zniknie internet - muzyka nie staje.
- (YouTube Data API v3 daje listy i informacje o filmach, ale nie dźwięk - dźwięk dalej pobiera YouTubeKit.)

## 1.29.5
- Nowe tło z okładki, jak w Apple Music: sama okładka, mocno rozmyta, w trzech wielkich warstwach (jedna odbita
  lustrzanie), które powoli obracają się i krążą w różne strony - po ekranie płyną prawdziwe kolory i kształty
  okładki (zamiast plam z wybranych kolorów). Szara okładka zostaje szara, kolorowa jest żywa.
- Jasne okładki (np. białe, różowe) są automatycznie mocniej przyciemnione, żeby biały tekst był czytelny.
- Przy zmianie piosenki nowa okładka płynnie przenika się ze starą; warstwy składa karta graficzna (bez przycinania).

## 1.29.4
- Płynne przejście między piosenkami: stara i nowa okładka z tytułem nakładają się w jednym miejscu (wcześniej
  na czas animacji stały obok siebie i wszystko skakało), krótszy i delikatniejszy ruch, odjeżdżająca piosenka
  do końca pokazuje swoją okładkę i tytuł, a nowa okładka jest od razu w dużej jakości, gdy jest w pamięci.
- Tło: kolory nowej piosenki przenikają się na jednym płótnie (wcześniej przez sekundę rysowały się dwa naraz,
  co przycinało), bez mignięcia czernią przy przełączaniu.
- Tekst przy zmianie piosenki tylko krótko się przenika (bez skalowania całej listy).

## 1.29.3
- Mniej opcji w Ustawieniach: znika wybór animacji tekstu, fali liter, rozmycia i „Usuń zapisane teksty”.
  Animacja liter i rozmycie dalszych linijek są zawsze włączone; rozmiar tekstu jest znowu w „Teksty i wygląd”.

## 1.29.2
- Usunięta animowana ikona grającej piosenki na liście (przy włączaniu piosenki rysowała czarne pole na liście);
  wraca zwykła ikonka głośnika. Tytuł w mini-odtwarzaczu przy zmianie piosenki tylko płynnie się przenika.

## 1.29.1
- Menu „•••” w odtwarzaczu jest krótsze: Dodaj do playlisty, Tekst piosenki (inna wersja, wcześniej / później,
  tłumaczenie), Wyłącznik czasowy (15 / 30 / 60 min, po piosence), Edytor dźwięku, Udostępnij.
- Tło z okładki naprawdę pasuje do okładki: szara okładka daje szare tło (koniec różowych plam z szumu JPEG),
  okładka częściowo szara - tło częściowo szare, a kolory są w takich proporcjach jak na okładce
  (kolor z malutkiego fragmentu nie zalewa już całego ekranu, nie ma też wymyślonych odcieni).

## 1.29.0 - idealne teksty
**Teksty szybciej**
- Wszystkie źródła tekstów i wszystkie warianty tytułu są pytane naraz (wcześniej po kolei), a większość źródeł
  ze słowami nie czeka już na rozpoznanie nagrania (ISRC) - startują od razu (czekają tylko te, które go używają).
- Tekst z czasem linijek pokazuje się od razu, gdy tylko jest gotowy, a wersja słowo po słowie podmienia go sama,
  gdy przyjdzie (mała plakietka „Szukam wersji słowo po słowie”).
- Gdy jest już tekst ze słowami, aplikacja czeka na ważniejsze (wolniejsze) źródło najwyżej 1,2 s, a nie do limitu czasu.
- Ta sama piosenka nie jest szukana dwa razy jednocześnie (np. pobieranie z wyprzedzeniem + odtwarzanie), a teksty
  całej biblioteki pobierane w tle ustępują miejsca piosence, która właśnie gra.
- „Nie znaleziono tekstu” pojawia się szybciej: ponowne szukanie tylko po błędzie sieci (wcześniej każde szukanie szło 2-4 razy).

**Teksty ładniej**
- Prawdziwe karaoke (iOS 18+): litery aktywnej linijki zapalają się dokładnie wtedy, gdy są śpiewane, miękką falą
  z lekkim uniesieniem. Przy tekstach z samym czasem linijek fala idzie w tempie śpiewu (można wyłączyć).
- Przerwy instrumentalne i intro: trzy kropki zapalają się po kolei i „oddychają”, a pod koniec przerwy znikają.
- Rozmycie dalszych linijek (przełącznik w Ustawieniach), płynniejsze przejścia między linijkami.
- Tekst można przewijać palcem - wtedy nie ucieka ani się nie rozmywa, a po chwili sam wraca do śpiewanej linijki
  (albo od razu przyciskiem „Wróć do śpiewanej linijki”).
- Zamiast kółka ładowania: migające „linijki”. Na końcu tekstu: skąd jest tekst.
- Linijka zmienia się bliżej początku śpiewu (zegar odtwarzacza tyka co 0,1 s - teraz z wyrównaniem).

**Nowe**
- Menu „•••” → **Tekst piosenki**: inna wersja tekstu, tekst wcześniej / później o 0,25 s, przywróć oryginalne czasy,
  szukaj tekstu od nowa. Przy „Nie znaleziono tekstu” jest przycisk „Szukaj jeszcze raz”.
- Menu „•••” → **Wyłącznik czasowy**: 15 / 30 / 45 / 60 / 90 min albo „po tej piosence” - muzyka łagodnie cichnie i staje.
- Ustawienia → Teksty piosenek: animacja liter, fala bez czasów słów, rozmycie, rozmiar tekstu, „Usuń zapisane teksty”.
- Animacje: przycisk play/pauza płynnie zmienia ikonę, przyciski sprężyście reagują na dotyk, serce podskakuje,
  mini-odtwarzacz ma pasek postępu i animowaną zmianę piosenki, grająca piosenka na liście ma falującą ikonę.

**Poprawki błędów**
- Ręcznie wybrana wersja tekstu nie jest już nadpisywana przez kończące się w tle wyszukiwanie.
- Dopasowanie tekstu ze słuchu nie podmienia już tekstu słowo po słowie gorszą wersją z linijkami.
- Po zmianie wersji tekstu nie zostaje stara mapa czasu ani stare fragmenty do wyciszenia przekleństw.
- Tłumaczenie tekstu nie pokazuje już tłumaczenia innej wersji tekstu tej samej piosenki.
- Źródło ze słowami, które pasowało do innego nagrania (inna długość), nie blokuje już lepszych źródeł.
- Stałe identyfikatory tekstów z Kugou i lyrics.ovh (wcześniej zmieniały się przy każdym uruchomieniu).

## 1.26.0
- Playlisty: jeden przycisk "Opublikuj…" (publicznie albo prywatnie - tylko z linkiem), link w formie .../1, przycisk "Udostępnij playlistę", Biblioteka playlist (Biblioteka → + → Biblioteka playlist).

## 1.24.0
- Publikowanie i udostępnianie playlist: menu playlisty → "Udostępnij" (lista piosenek + link) albo "Opublikuj (skopiuj link)". Link musicplayer://… otwarty na telefonie znajomego sam dodaje playlistę; można go też wkleić w Importuj z linku.
- Napisy i przyciski, które zlewały się z tłem (biały akcent na jasnym tle), są teraz zawsze czytelne.

## 1.23.0
- Chromecast / Google TV: dotknięcie urządzenia na liście łączy się przez Wi-Fi i gra to samo co telefon (pauza i zmiana utworu podążają za telefonem).
- Strona na innym urządzeniu: pewniejsze odtwarzanie dźwięku (pobieranie piosenki od razu, przycisk gdy przeglądarka blokuje dźwięk, komunikaty o błędach).

## 1.22.0
- Strona na innym urządzeniu: ikony zamiast emotek, przewijany tekst (po kilku sekundach wraca do śpiewanej linijki), lżejsza animacja, ukrywanie tekstu, przycisk wyjścia, po połączeniu od razu startuje odtwarzanie.
- Radio: ikony dla wszystkich stacji (logo, ikona strony, a gdy brak - kolorowy kafelek z literami), własna ikona (przytrzymaj stację → "Zmień ikonę").
- Ekran radia: "Łączenie…" → "Wykrywam utwór…", głośność, animowany tekst, rozpoznawanie utworu ze strumienia (AudD) razem z miejscem w piosence.
- Teksty: nowa, płynna animacja liter (60 klatek/s) dla każdej piosenki z czasem, szybsze wyszukiwanie tekstu (źródła naraz), podświetlanie zawsze włączone.
- Urządzenia: Bluetooth (parowanie, lista wyjść), AirPlay, wyszukiwanie telewizorów/głośników/aut w Wi-Fi i Bluetooth, strona z tekstem na innym urządzeniu (QR).
- Rozpoznawanie piosenek z mikrofonu: 2 próby, zapasowy token, czytelniejsze błędy.
- Szybsze pobieranie piosenek (do 8 kawałków naraz), usunięte szare paski pobierania, usunięty wybór online/offline.

## 1.19.0
- Ciche pobieranie w tle całej biblioteki, gdy jest internet (też po powrocie sieci).
- Teksty: nowa, płynna animacja jak w Spotify, koniec fałszywego "brak tekstu", stabilna synchronizacja (teksty ze słowami nie są już przesuwane), źródła wybierane automatycznie (wszystkie naraz).
- Wyszukiwanie tylko w YouTube Music; import playlist ze Spotify dopasowuje piosenki w YouTube Music po okładce, a gdy jej nie ma - po najtrafniejszym wyniku.
- Lepszy liquid glass.

# Music Player – odtwarzacz muzyki z YouTube (iOS)

Aplikacja SwiftUI (iOS 17+, iPhone). Wygląd jak ekran tekstów w Apple Music (bez "Śpiewaj"),
z rozmytym, delikatnie poruszającym się tłem z okładki i szkłem "Liquid Glass". Cały interfejs jest po polsku.

## Co potrafi
- Wyszukiwanie w YouTube (YouTube Data API v3) i odtwarzanie natywne (YouTubeKit + AVPlayer), działa w tle i na zablokowanym ekranie.
- **Teksty zsynchronizowane linia po linii** (LRCLIB), kliknięcie linii = przewinięcie; korekta czasu
  tekstu (±0,5 s) w menu "•••".
- Playlisty: tworzenie, zmiana nazwy, kolejność, usuwanie. **Import playlisty lub pojedynczego filmu
  z linku YouTube** (`https://…`).
- Kolejka, shuffle, powtarzanie.
- Spotify: import playlist, albumów i pojedynczych piosenek oraz wyszukiwanie (przełącznik YouTube / Spotify w zakładce Szukaj).
- Ustawienia: tło (kolorowy blur z okładki / czarne / białe) i przyciemnienie blurowanego tła. Szkło to zawsze
  Liquid Glass. Przewodnik "Jak korzystać z aplikacji" pokazuje się przy pierwszym uruchomieniu i jest w Ustawieniach.
- Sterowanie z iPhone'a: ekran blokady, słuchawki, AirPods, Centrum sterowania – play/pauza,
  następny/poprzedni,
  przewijanie suwakiem. Ekran blokady pokazuje zawsze przyciski następny/poprzedni. Głośność = systemowa.

## Jak zbudować .ipa (GitHub Actions) – wystarczy telefon
1. Wejdź na github.com → **New repository** (może być prywatne).
2. Wgraj **zawartość** tego projektu do repo (rozpakowany; `project.yml`, `Lumen/`, `Packages/` i `.github/`
   mają być w głównym katalogu repo). Na komputerze: `git init && git add . && git commit -m init && git push`.
   Na telefonie możesz też wgrać cały ZIP do głównego katalogu repo – workflow sam go rozpakuje,
   ale wtedy plik `.github/workflows/build-ipa.yml` dodaj ręcznie (Add file → Create new file).
4. Zakładka **Actions → Build iOS IPA → Run workflow**. Po ok. 5–10 min:
   - plik `MusicPlayer.ipa` jest w **Artifacts** (`MusicPlayer-ipa`) oraz w **Releases**.
5. (Opcjonalnie) **Settings → Secrets and variables → Actions → New secret** `YOUTUBE_API_KEY`
   – klucz zostanie wbudowany w aplikację. Możesz też wpisać go w aplikacji (Ustawienia).

Masz komputer? Możesz też wypakować ZIP-a, wypchnąć całość do repo (workflow jest w `.github/workflows/`).

## Instalacja .ipa na iPhonie
Plik z GitHuba jest **niepodpisany**. Trzeba go podpisać własnym Apple ID:
- **Sideloadly** lub **AltStore** (komputer Windows/Mac, darmowe Apple ID, odświeżanie co 7 dni), albo
- własny certyfikat Apple Developer + narzędzie do podpisywania.
Bez podpisu iOS go nie zainstaluje.

## Klucz YouTube Data API
Klucz jest wbudowany w aplikację (`YOUTUBE_API_KEY` w `project.yml`, można go nadpisać sekretem
`YOUTUBE_API_KEY` w GitHub Actions). W aplikacji nie ma już pola do zmiany klucza.
Limit: ok. 100 wyszukiwań dziennie (import playlisty kosztuje prawie nic).

## Ważne
- Odtwarzanie idzie **natywnie**: [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) (wbudowany w
  `Packages/YouTubeKit`) pobiera bezpośredni adres strumienia audio (AAC/m4a), a gra go `AVPlayer`.
  Nie ma już WebView ani osadzonego odtwarzacza YouTube, więc: brak reklam, brak błędów 152/153,
  brak zależności od osadzania, a muzyka gra w tle i na zablokowanym ekranie tak jak w zwykłym odtwarzaczu.
- Do wyszukiwania i importu playlist nadal używany jest YouTube Data API (klucz niżej).
- Tylko do użytku osobistego (sideload), niezgodne z regulaminem YouTube, więc nie nadaje się do App Store.
- Gdy piosenka nie startuje: Ustawienia → Odtwarzacz → **Odśwież strumień bieżącej piosenki**.
- Wydajność: tło animowane jest przez Core Animation (bez przeliczania co klatkę), a miniaturki są
  cache'owane. Jeśli nadal coś zwalnia, wybierz w Ustawieniach czarne lub białe tło.
- Kod nie został skompilowany w środowisku, w którym powstał (brak Xcode). Pierwszy build na GitHubie
  jest pierwszą kompilacją – jeśli się wysypie, w Artifacts jest `xcodebuild-log`; wklej błędy
  (linie z `error:`) a poprawię.

## Co nowego w 1.18.0 (funkcje z BitChord)
- **Teksty słowo po słowie / sylaba po sylabie** z nowych źródeł: lrc.red, BiniLyrics, BetterLyrics (+ Portato/QQ), LyricsPlus,
  Unison, SimpMusic (domyślnie wyłączony). Parsery TTML (Apple Music), enhanced LRC i QRC. Pierwsze źródło z góry listy, które
  ma czasy słów, wygrywa; LRCLIB/NetEase/Kugou zostają jako zapas. Kolejność i włączanie: Ustawienia → Źródła tekstów.
- Wyciszanie przekleństw trafia dokładnie w słowo, gdy źródło zna czasy słów.
- Wybór wersji tekstu ma teraz listę „Źródła tekstów” (każde źródło osobno, z oznaczeniem „słowo po słowie”).
- **Wyszukiwanie w YouTube Music** (domyślne): bez klucza API i bez dziennego limitu, czysty tytuł i wykonawca, podpowiedzi
  podczas pisania. Przełącznik źródła w zakładce Szukaj: YouTube Music / YouTube / Spotify.
- Ustawienia: przełącznik „Podświetlanie słów”.
- Kod nie był kompilowany (brak Xcode); przy błędach w GitHub Actions wklej linie z `error:`.
- Pominięte na razie: PaxSenix, Musixmatch, Genius, napisy YouTube (kolejne etapy).
- Uwaga licencyjna: kod portowany z BitChord jest na licencji GPLv3 - do użytku własnego bez problemu, ale publiczne
  udostępnianie aplikacji wymaga wydania źródeł na GPLv3.

## Co nowego w 1.16.0 (lepsze teksty)
- Trzecie źródło tekstów (Kugou) obok LRCLIB i NetEase oraz tekst bez czasów z lyrics.ovh jako ostatnia deska ratunku.
- Gdy jest tekst bez czasów: czasy linijek są ustawiane po tym, co słychać w nagraniu (rozpoznawanie mowy na urządzeniu).
- Gdy nie ma żadnego tekstu: aplikacja pisze go ze słuchu po pobraniu piosenki (źródło „Auto”, mogą być błędy).

## Co nowego w 1.15.0
- Ulubione (serce w odtwarzaczu), tekst słowo po słowie, tłumaczenie tekstu (Ustawienia: język), edytor dźwięku
  (menu „•••”: slowed, nightcore, szybkość), import z Spotify i Apple Music (publiczne linki), rozpoznawanie
  piosenki (AudD), tempo tła, szybsze pobieranie (4 kawałki naraz).
- Kod nie był kompilowany; przy błędach w GitHub Actions wklej linie z `error:`.

## Co nowego w 1.5.0
- **Import playlisty pobiera wszystkie piosenki** w tle (3 naraz, z paskiem postępu „Pobieranie piosenek: x/y”).
  W playlistach jest też przycisk „Pobierz”.
- Spotify: import playlist, albumów i pojedynczych piosenek oraz wyszukiwanie (przełącznik YouTube / Spotify w zakładce Szukaj).
- Ustawienia: usunięto sekcję z rozmiarem pamięci, jest za to przycisk „Usuń wszystkie pobrane piosenki”.
- **Inteligentne dopasowanie tekstu:** po pobraniu piosenki aplikacja „nasłuchuje” jej (rozpoznawanie mowy Apple,
  na urządzeniu), porównuje usłyszane słowa z linijkami tekstu i sama ustawia przesunięcie oraz tempo
  (dwa fragmenty: początek i ok. 60% utworu). Stosowane tylko, gdy min. 3 linijki się zgadzają. Wynik jest
  zapamiętany. Ręcznie: menu „•••” → „Dopasuj tekst automatycznie”. Działa zawsze (bez przełącznika w Ustawieniach); zgodę na rozpoznawanie mowy aplikacja prosi przy pierwszym uruchomieniu.

## Co nowego w 1.11.0
- Cenzura przekleństw (polski, angielski, niemiecki, hiszpański, francuski, włoski, rosyjski): w tekście wulgaryzmy
  zamieniają się w gwiazdki (np. ku***), a w nagraniu cichną na ułamek sekundy z krótkim sygnałem. Moment jest
  szacowany z czasu linijki tekstu, więc bywa niedokładny. Przełącznik „Cenzura przekleństw” jest w Ustawieniach
  (domyślnie włączony).

## Co nowego w 1.10.0
- Szukaj: animacja pisania w polu wyszukiwania (tekst wpisuje się literka po literce i wymazuje), animacja czyszczenia
  (przycisk ✕ znika, wyniki się wygaszają).
- Tło z okładki: kolory płynnie przechodzą z jednej piosenki w drugą (wygaszanie zamiast skoku).
- Dodawanie piosenki do playlisty i tworzenie playlisty: animowany „ptaszek”, wibracja, a nowe pozycje wjeżdżają na listę.

## Co nowego w 1.9.1
- Spotify: import playlist, albumów i pojedynczych piosenek oraz wyszukiwanie (przełącznik YouTube / Spotify w zakładce Szukaj).
- Ustawienia: długie napisy zawijają się do kolejnej linijki zamiast wychodzić poza ekran (skrócono „Kolor akcentu”).

## Co nowego w 1.9.0
- Animacja przełączania piosenek w odtwarzaczu: okładka i tytuł wjeżdżają z boku (następna z prawej, poprzednia
  z lewej) z płynnym wygaszaniem poprzedniej.

## Co nowego w 1.8.2
- Brak internetu nie jest już mylony z „Nie znaleziono tekstu”: bez sieci pokazuje się komunikat, a tekst pojawia się
  sam (i dopasowuje do nagrania), gdy tylko internet wróci - bez wychodzenia z piosenki i klikania.
- Teksty wszystkich piosenek z playlist pobierają się w tle i zapisują na dysku, więc są też offline.

## Co nowego w 1.8.1
- Wszystkie miniatury piosenek zapisują się na stałe na dysku (wcześniej tylko w pamięci, więc bez internetu
  zostawały te kilka, które były na ikonie playlisty). Miniatury całej biblioteki dociągają się w tle, a duża okładka
  zapisuje się razem z pobraniem piosenki.

## Co nowego w 1.8.0
- W odtwarzaczu, gdy bieżąca piosenka się pobiera, pojawia się powiadomienie z procentem pobrania (np. „Pobieranie
  piosenki: 42%”) i paskiem postępu, aktualizowane na bieżąco. Znika po pobraniu.

## Co nowego w 1.7.3
- Pobrane piosenki zostają na stałe i grają bez internetu: aplikacja nie usuwa już plików z dysku z powodu
  dziwnego czasu trwania (usuwa je tylko przycisk „Usuń wszystkie pobrane piosenki”). Przy dziwnym czasie pokazuje
  prawdziwą długość piosenki i kończy ją w odpowiednim momencie.

## Co nowego w 1.7.2
- Dokładniejszy wybór wersji tekstu: nasłuch 4 fragmentów piosenki (zamiast 2) i do 8 kandydatów. Wygrywa wersja,
  która zgadza się z nagraniem w najwięcej miejsc, więc znika problem „w piosence inna zwrotka niż w tekście”.
  Punkty niezgodne z resztą są odrzucane przy liczeniu czasu i tempa.
- Teksty są widoczne od razu po wejściu w piosenkę i po zmianie piosenki (bez klikania przycisku tekstu).

## Co nowego w 1.7.1
- Lepsze rozmycie tła z okładki: tło pokazuje wszystkie kolory okładki (rozciągnięte na cały ekran), a plamy kolorów
  mają osobne miejsca i wyraziste, różne barwy zamiast jednego brudnego koloru.
- Z tekstów znikają dopiski „Generated by LRCGENERATOR”.

## Co nowego w 1.7.0
- Mądre słuchanie piosenki: po pobraniu aplikacja szybko nasłuchuje nagrania (dwa fragmenty naraz), zamienia je na
  tekst i porównuje ze wszystkimi znalezionymi wersjami tekstu (LRCLIB i NetEase). Wygrywa wersja, która najlepiej
  zgadza się z tym, co słychać, i do niej dopasowywany jest czas i tempo. Bez żadnych przełączników.
- Naprawa piosenki, która po kilku sekundach (np. 0:08) wracała na 0:00: zepsuty plik z dysku jest wykrywany
  przed odtworzeniem, więc piosenka gra od razu poprawnie.

## Co nowego w 1.6.7
- Z widoku playlisty usunięto przycisk „Pobierz” (piosenki i tak pobierają się same przy imporcie i przy graniu).

## Co nowego w 1.6.6
- Gdy aplikacja jest otwarta na ekranie, telefon nie przyciemnia ekranu i nie blokuje się sam (po wyjściu z aplikacji
  wraca normalne zachowanie, a muzyka gra dalej w tle).

## Co nowego w 1.6.3
- Naprawa podwojonego czasu piosenki w playliście (np. 2:01 pokazywało 4:02): pobieranie nie może już dokleić
  pliku drugi raz, a uszkodzony plik z dysku jest usuwany i piosenka gra od nowa ze strumienia.
- Z menu „•••” usunięto „Dopasuj tekst automatycznie” i „Wybierz inną wersję tekstu” (dopasowanie działa samo).

## Co nowego w 1.6.2
- Domyślna ikona playlisty to siatka 2x2 z okładek pierwszych 4 piosenek (własną ikonę nadal możesz ustawić).

## Co nowego w 1.6.1
- Menu „•••” w odtwarzaczu: usunięto ręczne przesuwanie i tempo tekstu oraz reset; zostało „Dopasuj tekst automatycznie”.
- Rozmywanie nieaktywnych linijek jest zawsze włączone (bez przełączników w Ustawieniach i w menu).

## Co nowego w 1.6.0
- Nowa ikona aplikacji (nuta na ciemnym tle).
- Usunięto przełącznik „Automatyczne dopasowanie tekstu” - dopasowanie działa zawsze, a prośba o zgodę na
  rozpoznawanie mowy pojawia się przy starcie aplikacji.
- Własna ikona playlisty: przytrzymaj playlistę w Bibliotece → „Zmień ikonę” albo ikona zdjęcia w widoku playlisty.
  Bez własnej ikony nadal widać okładkę pierwszej piosenki.

## Co nowego w 1.4.0
- **Piosenki zapisują się na stałe:** pierwsze odtworzenie leci ze strumienia, a w tle utwór jest pobierany do
  `Application Support/Lumen/Audio`. Następny utwór z kolejki jest pobierany z wyprzedzeniem. Każde kolejne
  odtworzenie startuje natychmiast i działa bez internetu. Teksty też zapisują się na stałe.
- **Teksty z dwóch źródeł naraz:** LRCLIB + NetEase, wybierana jest wersja o najbliższym czasie trwania do filmu
  (inna wersja = inne tempo). W menu „•••”: wybór innej wersji, tempo ±1% i czas ±0,5 s (osobno dla każdej piosenki).
- **Rozmycie tekstu** działa na całej długości tekstu (nie tylko blisko aktywnej linijki) i można je wyłączyć
  w Ustawieniach albo w menu „•••”.
- **Kolory:** tekstów i ikon, akcentu (menu, suwaki, przyciski) i tekstu piosenki.
- **Tło:** okładka (z rozmyciem lub bez), kolor / gradient, własne zdjęcie z galerii (z rozmyciem lub bez), czarne, białe.
- Usunięto przyciski „wyczyść pamięć” i „odśwież strumień”.

## Co nowego w 1.3.0
**Muzyka w tle (bez obejść):**
- `UIBackgroundModes: audio` + `AVAudioSession` `.playback` + `AVPlayer`: iOS sam pilnuje, żeby dźwięk grał.
- Adres następnej piosenki jest pobierany z wyprzedzeniem, więc przejście do kolejnej w tle jest natychmiastowe.
- Obsługa przerwań (telefon, budzik), odłączenia słuchawek i ekranu blokady (play/pauza/następny/poprzedni/przewijanie).
- Watchdog: jeśli adres strumienia wygaśnie albo zerwie się sieć, aplikacja sama pobiera nowy i wznawia od tego samego miejsca.

**Teksty zsynchronizowane z piosenką:**
- Zegar odtwarzacza tyka 10 razy na sekundę (wcześniej zdarzenia z YouTube przychodziły co 0,2–0,5 s).
- Usunięto sztuczne wyprzedzanie tekstu o 0,25 s.
- Uwzględniane jest opóźnienie wyjścia audio (Bluetooth ~0,2 s), przez które tekst wcześniej uciekał do przodu.
- Dobór tekstu mocniej premiuje wersję o takim samym czasie trwania jak film (inna wersja = rozjazd).
- Jeśli film ma np. intro, którego nie ma w wersji albumowej, popraw przesunięcie przyciskami przy tekście –
  zapamiętuje się osobno dla każdej piosenki.
