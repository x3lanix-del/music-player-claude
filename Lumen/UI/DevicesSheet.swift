import SwiftUI
import ExternalAccessory
import CoreBluetooth

/// Urządzenia: gdzie gra dźwięk, łączenie przez Bluetooth / AirPlay (Wi‑Fi), wyszukiwanie telewizorów, głośników i aut
/// w pobliżu oraz strona z animowanym tekstem do otwarcia na innym urządzeniu.
@MainActor
struct DevicesSheet: View {
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toast: ToastCenter
    @Environment(\.dismiss) private var dismiss

    @StateObject private var discovery = DeviceDiscovery()
    @StateObject private var picker = RoutePickerBox()
    @ObservedObject private var bridge = RemoteLyricsBridge.shared
    @ObservedObject private var cast = CastController.shared

    var body: some View {
        NavigationStack {
            List {
                routeSection
                bluetoothSection
                wifiSection
                remoteSection
            }
            .navigationTitle("Urządzenia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Gotowe") { dismiss() } }
            }
            .background(RoutePickerAnchor(box: picker).frame(width: 44, height: 44).allowsHitTesting(false))
        }
        .presentationDetents([.large])
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    // MARK: Teraz gra

    private var routeSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: discovery.route.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(discovery.route.name).font(.system(size: 17, weight: .semibold))
                    Text(discovery.route.kindText).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if engine.phoneMuted {
                    Text("wyciszony").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                }
            }
            Button { picker.present() } label: {
                Label("Wybierz, gdzie ma grać (Bluetooth / AirPlay)", systemImage: "airplayaudio")
            }
        } header: {
            Text("Teraz gra na")
        } footer: {
            Text("Lista systemowa pokazuje sparowane urządzenia Bluetooth oraz urządzenia AirPlay w Twojej sieci Wi‑Fi (Apple TV, wiele telewizorów i głośników).")
        }
    }

    // MARK: Bluetooth

    private var bluetoothSection: some View {
        Section {
            switch discovery.bluetoothState {
            case .poweredOff:
                statusRow("Bluetooth jest wyłączony", icon: "bolt.slash", action: ("Otwórz ustawienia", SystemLinks.openBluetoothSettings))
            case .unauthorized:
                statusRow("Aplikacja nie ma zgody na Bluetooth", icon: "hand.raised", action: ("Ustawienia aplikacji", SystemLinks.openAppSettings))
            case .unsupported:
                statusRow("To urządzenie nie obsługuje Bluetooth", icon: "xmark.circle", action: nil)
            default:
                EmptyView()
            }

            Button { picker.present() } label: {
                Label("Połącz ze sparowanym urządzeniem", systemImage: "headphones")
            }
            Button { pairNew(filter: nil) } label: {
                Label("Sparuj nowe urządzenie Bluetooth", systemImage: "plus.circle")
            }
            Button { SystemLinks.openBluetoothSettings() } label: {
                Label("Otwórz ustawienia Bluetooth", systemImage: "gearshape")
            }

            ForEach(discovery.bluetoothDevices) { d in
                Button { pairNew(filter: nil) } label: { deviceRow(d, label: "Połącz") }
                    .buttonStyle(.plain)
            }
            if discovery.scanning && discovery.bluetoothDevices.isEmpty && discovery.bluetoothState == .poweredOn {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Szukam urządzeń Bluetooth…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Bluetooth")
        } footer: {
            Text("Skanowanie widzi urządzenia, które się ogłaszają (słuchawki, głośniki, wiele aut). „Połącz” otwiera systemową listę urządzeń do sparowania - włącz wcześniej na urządzeniu tryb parowania. Gdy lista jest pusta, sparuj je w Ustawieniach Bluetooth (przycisk poniżej) - potem pojawi się na liście wyjść.")
        }
    }

    // MARK: Wi‑Fi

    private var wifiSection: some View {
        Section {
            if discovery.localNetworkDenied {
                statusRow("Brak zgody na sieć lokalną - bez niej nie znajdę urządzeń w Wi‑Fi",
                          icon: "wifi.exclamationmark", action: ("Ustawienia aplikacji", SystemLinks.openAppSettings))
            }
            if cast.connected, let name = cast.deviceName {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Gra na: \(name)", systemImage: "play.tv").font(.system(size: 16, weight: .semibold))
                    if !cast.status.isEmpty {
                        Text(cast.status).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { cast.stop() } label: { Label("Rozłącz", systemImage: "xmark.circle") }
                }
            }
            ForEach(discovery.wifiDevices) { d in
                Button {
                    if d.canCast {
                        cast.start(d, engine: engine, settings: settings)
                        toast.show("Łączę z \(d.name)…")
                    } else if d.canRoute {
                        picker.present()
                    } else {
                        // Urządzenie bez AirPlay i Chromecasta: od razu uruchamiamy stronę z tekstem do otwarcia na nim.
                        bridge.start(engine: engine, settings: settings)
                        toast.show("Otwórz podany adres na urządzeniu: \(d.name)")
                    }
                } label: {
                    deviceRow(d, label: d.canCast ? "Połącz" : (d.canRoute ? "Wybierz" : "Otwórz stronę"))
                }
                .buttonStyle(.plain)
            }
            if discovery.scanning && discovery.wifiDevices.isEmpty && !discovery.localNetworkDenied {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Szukam w sieci Wi‑Fi…").foregroundStyle(.secondary)
                }
            } else if !discovery.scanning && discovery.wifiDevices.isEmpty && !discovery.localNetworkDenied {
                Text("Nic nie znaleziono. Telefon i urządzenie muszą być w tej samej sieci Wi‑Fi.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Button { discovery.restart() } label: {
                Label(discovery.scanning ? "Szukam…" : "Szukaj ponownie", systemImage: "arrow.clockwise")
            }
            .disabled(discovery.scanning)
        } header: {
            Text("Telewizory, głośniki i inne w Wi‑Fi")
        } footer: {
            Text("Dotknij Chromecasta / Google TV, żeby od razu zagrał to, co gra w telefonie (telefon cichnie). AirPlay wybierzesz z listy systemowej. Pozostałe urządzenia otworzą stronę z tekstem w przeglądarce.")
        }
    }

    // MARK: Strona z tekstem

    private var remoteSection: some View {
        Section {
            if bridge.running, let address = bridge.address {
                VStack(alignment: .center, spacing: 12) {
                    if let qr = LocalNetwork.qr(address) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 170, height: 170)
                            .padding(10)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Text(address)
                        .font(.system(size: 19, weight: .bold).monospaced())
                        .textSelection(.enabled)
                    Text("Zeskanuj kod telefonem albo wpisz adres w przeglądarce telewizora / komputera (ta sama sieć Wi‑Fi).")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                ShareLink(item: address) { Label("Udostępnij adres", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { bridge.stop() } label: {
                    Label("Zatrzymaj stronę", systemImage: "stop.circle")
                }
            } else {
                Button {
                    bridge.start(engine: engine, settings: settings)
                } label: {
                    Label("Odtwórz na innym urządzeniu", systemImage: "tv.and.hifispeaker.fill")
                }
                if bridge.failed {
                    Text("Nie udało się uruchomić strony. Sprawdź, czy telefon jest w sieci Wi‑Fi, i zezwól aplikacji na sieć lokalną.")
                        .font(.system(size: 14)).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Tekst i dźwięk na innym urządzeniu")
        } footer: {
            Text("Telefon uruchamia małą stronę w Twojej sieci. Otwarta w przeglądarce telewizora, komputera albo drugiego telefonu pokazuje animowany tekst i przyciski (poprzednia, pauza, następna). Przyciskiem „Graj dźwięk na tym urządzeniu\" dźwięk przechodzi na to urządzenie, a telefon cichnie. Dotyczy pobranych piosenek i radia. Strona działa, dopóki aplikacja jest otwarta.")
        }
    }

    // MARK: Elementy

    private func deviceRow(_ d: NearbyDevice, label: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: d.symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(d.techText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.14), in: Capsule())
                .foregroundStyle(Color.primary)
        }
        .contentShape(Rectangle())
    }

    private func statusRow(_ text: String, icon: String, action: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: icon).foregroundStyle(.orange).font(.system(size: 14, weight: .semibold))
            if let action = action {
                Button(action.0, action: action.1)
            }
        }
    }

    /// Systemowy wybór urządzenia Bluetooth do sparowania (z filtrem po nazwie, gdy dotknięto konkretne urządzenie).
    private func pairNew(filter: String?) {
        let predicate = filter.map { NSPredicate(format: "SELF CONTAINS[cd] %@", $0) }
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: predicate) { error in
            DispatchQueue.main.async {
                guard let error = error as NSError? else {
                    discovery.refreshRoute()
                    toast.show("Sparowano. Wybierz je na liście wyjść dźwięku.")
                    picker.present()
                    return
                }
                // Anulowanie przez użytkownika nie jest błędem.
                if error.code == EABluetoothAccessoryPickerError.Code.alreadyConnected.rawValue {
                    toast.show("To urządzenie jest już połączone")
                    picker.present()
                } else if error.code != EABluetoothAccessoryPickerError.Code.resultCancelled.rawValue {
                    toast.show("Nie znalazłem urządzenia do sparowania - otwieram ustawienia Bluetooth")
                    SystemLinks.openBluetoothSettings()
                }
            }
        }
    }
}
