import Foundation
import AVFoundation
import AVKit
import Network
import CoreBluetooth
import UIKit
import SwiftUI

// MARK: - Modele

struct NearbyDevice: Identifiable, Hashable {
    enum Kind: String { case tv, speaker, car, computer, other }
    enum Link: String { case wifi, bluetooth }

    let id: String
    let name: String
    let kind: Kind
    let link: Link
    /// Krótki opis technologii, np. "AirPlay", "Chromecast", "Spotify Connect", "Bluetooth".
    let tech: Set<String>
    /// Adres usługi w sieci (do połączenia, np. z Chromecastem).
    var endpoint: NWEndpoint? = nil

    var techText: String { tech.sorted().joined(separator: " · ") }

    var symbol: String {
        switch kind {
        case .tv: return "tv"
        case .speaker: return link == .bluetooth ? "hifispeaker" : "hifispeaker.2"
        case .car: return "car"
        case .computer: return "desktopcomputer"
        case .other: return link == .bluetooth ? "dot.radiowaves.left.and.right" : "wifi"
        }
    }

    /// Czy można je wybrać jako wyjście dźwięku z systemowej listy (AirPlay / Bluetooth).
    var canRoute: Bool { tech.contains("AirPlay") }
    /// Chromecast / Google TV: aplikacja potrafi sama połączyć się i zagrać na nim.
    var canCast: Bool { tech.contains("Chromecast") && endpoint != nil }
}

/// Dokąd teraz idzie dźwięk.
struct AudioRouteInfo: Equatable {
    var name: String
    var symbol: String
    var kindText: String
}

// MARK: - Wykrywanie urządzeń

/// Szuka w pobliżu: urządzeń w sieci Wi‑Fi (Bonjour: AirPlay, Chromecast, Spotify Connect, Sonos, Android TV…)
/// oraz urządzeń Bluetooth (skanowanie BLE) i pokazuje, dokąd teraz gra dźwięk.
/// Wszystkie wywołania zwrotne idą przez główną kolejkę, więc `@Published` zmienia się tylko na głównym wątku.
final class DeviceDiscovery: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var route = AudioRouteInfo(name: "Głośnik telefonu", symbol: "iphone", kindText: "Telefon")
    @Published private(set) var wifiDevices: [NearbyDevice] = []
    @Published private(set) var bluetoothDevices: [NearbyDevice] = []
    @Published private(set) var scanning = false
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var localNetworkDenied = false

    static let services: [(type: String, label: String)] = [
        ("_airplay._tcp", "AirPlay"),
        ("_raop._tcp", "AirPlay"),
        ("_googlecast._tcp", "Chromecast"),
        ("_spotify-connect._tcp", "Spotify Connect"),
        ("_sonos._tcp", "Sonos"),
        ("_amzn-wplay._tcp", "Alexa / Fire TV"),
        ("_samsungmsf._tcp", "Samsung TV"),
        ("_androidtvremote2._tcp", "Android TV")
    ]

    private var browsers: [NWBrowser] = []
    private var found: [String: NearbyDevice] = [:]          // klucz = znormalizowana nazwa
    private var central: CBCentralManager?
    private var bleFound: [UUID: (name: String, rssi: Int)] = [:]
    private var stopTimer: Timer?
    private var routeObserver: NSObjectProtocol?

    override init() {
        super.init()
        refreshRoute()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshRoute() }
    }

    deinit {
        if let o = routeObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Trasa dźwięku

    func refreshRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let out = outputs.first else {
            route = AudioRouteInfo(name: "Głośnik telefonu", symbol: "iphone", kindText: "Telefon")
            return
        }
        let name = out.portName
        switch out.portType {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            route = AudioRouteInfo(name: name, symbol: "headphones", kindText: "Bluetooth")
        case .airPlay:
            route = AudioRouteInfo(name: name, symbol: "airplayaudio", kindText: "AirPlay (Wi‑Fi)")
        case .carAudio:
            route = AudioRouteInfo(name: name, symbol: "car", kindText: "Samochód")
        case .HDMI, .displayPort:
            route = AudioRouteInfo(name: name, symbol: "tv", kindText: "HDMI / telewizor")
        case .headphones:
            route = AudioRouteInfo(name: name, symbol: "headphones", kindText: "Słuchawki")
        case .usbAudio:
            route = AudioRouteInfo(name: name, symbol: "cable.connector", kindText: "USB")
        case .builtInReceiver:
            route = AudioRouteInfo(name: "Słuchawka telefonu", symbol: "iphone", kindText: "Telefon")
        default:
            route = AudioRouteInfo(name: name.isEmpty ? "Głośnik telefonu" : name, symbol: "iphone", kindText: "Telefon")
        }
    }

    // MARK: Start / stop

    func start() {
        guard !scanning else { return }
        scanning = true
        found = [:]
        wifiDevices = []
        bleFound = [:]
        bluetoothDevices = []
        localNetworkDenied = false
        refreshRoute()
        startBonjour()
        startBluetooth()
        // Po ~25 s kończymy skanowanie (oszczędza baterię); przycisk "Szukaj ponownie" uruchamia je znowu.
        stopTimer?.invalidate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in self?.stop() }
    }

    func stop() {
        stopTimer?.invalidate()
        stopTimer = nil
        for b in browsers { b.cancel() }
        browsers = []
        central?.stopScan()
        central = nil
        scanning = false
    }

    func restart() {
        stop()
        start()
    }

    // MARK: Wi‑Fi (Bonjour)

    private func startBonjour() {
        for svc in DeviceDiscovery.services {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: svc.type, domain: nil), using: .tcp)
            let label = svc.label
            let type = svc.type
            browser.stateUpdateHandler = { [weak self] state in
                if case .waiting = state { self?.localNetworkDenied = true }
                if case .ready = state { self?.localNetworkDenied = false }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.handle(results: results, label: label, type: type)
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    private func handle(results: Set<NWBrowser.Result>, label: String, type: String) {
        for r in results {
            guard case let .service(rawName, _, _, _) = r.endpoint else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = r.metadata { txt = record.dictionary }
            var name = rawName
            // AirPlay RAOP: "AABBCCDDEEFF@Salon" - bierzemy nazwę po "@".
            if type == "_raop._tcp", let at = rawName.firstIndex(of: "@") { name = String(rawName[rawName.index(after: at)...]) }
            // Chromecast: czytelna nazwa jest w polu TXT "fn".
            if type == "_googlecast._tcp", let fn = txt["fn"], !fn.isEmpty { name = fn }
            let model = (txt["md"] ?? txt["model"] ?? "").lowercased()
            let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !key.isEmpty else { continue }
            let guessed = DeviceDiscovery.kind(name: name, model: model, label: label)
            let castEndpoint: NWEndpoint? = (label == "Chromecast") ? r.endpoint : nil
            if let old = found[key] {
                found[key] = NearbyDevice(id: old.id, name: old.name, kind: old.kind == .other ? guessed : old.kind,
                                          link: .wifi, tech: old.tech.union([label]), endpoint: castEndpoint ?? old.endpoint)
            } else {
                found[key] = NearbyDevice(id: "wifi-" + key, name: name, kind: guessed, link: .wifi, tech: [label],
                                          endpoint: castEndpoint)
            }
        }
        publishWifi()
    }

    private func publishWifi() {
        wifiDevices = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func kind(name: String, model: String, label: String) -> NearbyDevice.Kind {
        let n = name.lowercased() + " " + model
        let tvWords = ["tv", "bravia", "samsung", "lg ", "webos", "vizio", "tcl", "hisense", "philips", "fire", "shield", "chromecast", "roku", "apple tv", "appletv", "sony", "google tv"]
        let spkWords = ["sonos", "homepod", "echo", "speaker", "soundbar", "nest", "audio", "głośnik", "glosnik", "jbl", "bose", "marshall", "denon", "yamaha", "heos", "beosound"]
        let carWords = ["car", "auto", "carplay", "bmw", "audi", "mercedes", "volkswagen", "vw", "skoda", "škoda", "toyota", "ford", "opel", "kia", "hyundai", "mazda", "volvo"]
        let pcWords = ["macbook", "imac", "mac mini", "mac studio", "windows", "desktop", "laptop", "pc"]
        if carWords.contains(where: { n.contains($0) }) { return .car }
        if spkWords.contains(where: { n.contains($0) }) { return .speaker }
        if tvWords.contains(where: { n.contains($0) }) { return .tv }
        if pcWords.contains(where: { n.contains($0) }) { return .computer }
        switch label {
        case "Samsung TV", "Android TV", "Alexa / Fire TV": return .tv
        case "Sonos": return .speaker
        default: return .other
        }
    }

    // MARK: Bluetooth

    private func startBluetooth() {
        // Pierwsze utworzenie managera pokazuje systemową prośbę o zgodę na Bluetooth.
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        bleFound[peripheral.identifier] = (name, RSSI.intValue)
        bluetoothDevices = bleFound
            .sorted { $0.value.rssi > $1.value.rssi }
            .map { id, v in
                NearbyDevice(id: "ble-" + id.uuidString, name: v.name,
                             kind: DeviceDiscovery.kind(name: v.name, model: "", label: "Bluetooth"),
                             link: .bluetooth, tech: ["Bluetooth"])
            }
    }
}

// MARK: - Systemowa lista wyjść dźwięku (AirPlay + sparowane Bluetooth)

/// Niewidoczny przycisk wyboru wyjścia; `present()` otwiera systemową listę (to ona łączy z AirPlay i Bluetooth).
final class RoutePickerBox: ObservableObject {
    fileprivate weak var view: AVRoutePickerView?

    func present() {
        guard let v = view else { return }
        for sub in v.subviews {
            if let b = sub as? UIButton {
                b.sendActions(for: .touchUpInside)
                return
            }
        }
    }
}

struct RoutePickerAnchor: UIViewRepresentable {
    let box: RoutePickerBox

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        v.prioritizesVideoDevices = false
        v.alpha = 0.02
        box.view = v
        return v
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        box.view = view
    }
}

enum SystemLinks {
    /// Ustawienia Bluetooth (gdy system na to pozwala), w ostateczności ustawienia aplikacji.
    static func openBluetoothSettings() {
        if let url = URL(string: "App-Prefs:root=Bluetooth") {
            UIApplication.shared.open(url, options: [:]) { ok in
                if !ok { openAppSettings() }
            }
        } else {
            openAppSettings()
        }
    }

    static func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
