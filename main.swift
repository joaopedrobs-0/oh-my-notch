// Oh My Notch! — ilha dinâmica no notch do Mac, com proteção auditiva nos fones.
// Ícone na barra de menus aparece só com fone conectado. Janela no estilo Ajustes do Sistema.

import SwiftUI
import AppKit
import CoreAudio
import AudioToolbox
import ServiceManagement
import ApplicationServices

// MARK: - Preferências

enum Prefs {
    static let d = UserDefaults.standard
    static var enabled: Bool { get { d.object(forKey: "enabled") as? Bool ?? true } set { d.set(newValue, forKey: "enabled") } }
    static var limit: Float { get { d.object(forKey: "limit") as? Float ?? 0.60 } set { d.set(newValue, forKey: "limit") } }
    static var overrides: [String: Bool] {
        get { d.dictionary(forKey: "overrides") as? [String: Bool] ?? [:] }
        set { d.set(newValue, forKey: "overrides") }
    }
    static var connectAnimation: Bool { get { d.object(forKey: "connectAnimation") as? Bool ?? true } }
    static var connectSound: Bool { get { d.object(forKey: "connectSound") as? Bool ?? true } }
    static var lockScreenWidget: Bool { get { d.object(forKey: "lockScreenWidget") as? Bool ?? true } }
    static var didSetupLogin: Bool { get { d.bool(forKey: "didSetupLogin") } set { d.set(newValue, forKey: "didSetupLogin") } }
}

// MARK: - CoreAudio

enum Audio {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
    }

    static func defaultOutput() -> AudioObjectID {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id)
        return id
    }

    static func allOutputDevices() -> [AudioObjectID] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var s = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var n: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &s, 0, nil, &n) == noErr && n > 0
        }
    }

    static func uint32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = addr(sel, scope)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &s) == noErr else { return nil }
        return s?.takeRetainedValue() as String?
    }

    static func name(_ id: AudioObjectID) -> String { string(id, kAudioObjectPropertyName) ?? "Desconhecido" }
    static func uid(_ id: AudioObjectID) -> String { string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)" }
    static func transport(_ id: AudioObjectID) -> UInt32 { uint32(id, kAudioDevicePropertyTransportType) ?? 0 }

    static func looksLikeHeadphones(_ id: AudioObjectID) -> Bool {
        let t = transport(id)
        if t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE { return true }
        if let ds = uint32(id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput), ds == 0x6864706E { return true } // 'hdpn'
        let n = name(id).lowercased()
        return ["headphone", "headset", "fone", "earbud", "airpods", "buds", "auricular"].contains { n.contains($0) }
    }

    static func volume(_ id: AudioObjectID) -> Float? {
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setVolume(_ id: AudioObjectID, _ value: Float) {
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var v = Float32(value)
        if AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) != noErr {
            for ch: UInt32 in [1, 2] {
                var c = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, ch)
                AudioObjectSetPropertyData(id, &c, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
            }
        }
    }
}

struct OutputDevice: Identifiable, Equatable {
    let id: String          // UID
    let audioID: AudioObjectID
    let name: String
    let transport: UInt32
    let autoHeadphone: Bool

    var kind: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeBuiltIn: return L("Integrado")
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return L("Monitor")
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "Virtual"
        default: return L("Outro")
        }
    }
    var symbol: String {
        if autoHeadphone { return "headphones" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplay.audio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "hifispeaker.fill"
        }
    }
}

// MARK: - Monitor

final class AudioMonitor: ObservableObject {
    static let shared = AudioMonitor()

    @Published private(set) var deviceName = "Nenhum"
    @Published private(set) var deviceUID = ""
    @Published private(set) var volume: Float = 0
    @Published private(set) var hasVolume = false
    @Published private(set) var isHeadphone = false
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var justClamped = false

    @Published var enabled = Prefs.enabled { didSet { Prefs.enabled = enabled; syncRule(); enforce() } }
    @Published var limit = Prefs.limit { didSet { Prefs.limit = limit; syncRule(); enforce() } }
    @Published var overrides = Prefs.overrides { didSet { Prefs.overrides = overrides; refresh() } }

    var isLimiting: Bool { enabled && isHeadphone }
    var limitPercent: Int { Int((limit * 100).rounded()) }

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var lastHeadUID = ""
    private var didInitialLoad = false
    private var watched = AudioObjectID(kAudioObjectUnknown)
    private var clampWork: DispatchWorkItem?

    private lazy var hwListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.deviceChanged() }
    }
    // Regra lida pela fila de áudio (fora da main) para corrigir o volume instantaneamente.
    private let lock = NSLock()
    private var rule: (device: AudioObjectID, active: Bool, limit: Float) = (0, false, 1)
    private let audioQueue = DispatchQueue(label: "volumeseguro.audio", qos: .userInteractive)

    private func syncRule() {
        lock.lock(); rule = (device, enabled && isHeadphone, limit); lock.unlock()
    }

    private lazy var devListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        // Corrige imediatamente, sem esperar a interface.
        self.lock.lock(); let r = self.rule; self.lock.unlock()
        if r.active, r.device != kAudioObjectUnknown, let v = Audio.volume(r.device), v > r.limit + 0.005 {
            Audio.setVolume(r.device, r.limit)
            DispatchQueue.main.async { self.flashClamp() }
        }
        DispatchQueue.main.async { self.refresh() }
    }

    private init() {
        for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var a = Audio.addr(sel)
            AudioObjectAddPropertyListenerBlock(Audio.system, &a, .main, hwListener)
        }
        deviceChanged()
        // As mudanças de volume e dispositivo chegam por avisos do CoreAudio (instantâneo);
        // isto é só uma rede de segurança lenta, para não gastar bateria.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func shouldLimit(_ d: OutputDevice) -> Bool { overrides[d.id] ?? d.autoHeadphone }

    func setLimit(_ d: OutputDevice, _ on: Bool) {
        var o = overrides
        o[d.id] = (on == d.autoHeadphone) ? nil : on
        overrides = o
    }

    private var lastDeviceChange = Date()

    private func deviceChanged() {
        lastDeviceChange = Date()
        if watched != kAudioObjectUnknown { watch(watched, add: false) }
        device = Audio.defaultOutput()
        watched = device
        if device != kAudioObjectUnknown { watch(device, add: true) }
        devices = Audio.allOutputDevices().map {
            OutputDevice(id: Audio.uid($0), audioID: $0, name: Audio.name($0),
                         transport: Audio.transport($0), autoHeadphone: Audio.looksLikeHeadphones($0))
        }.sorted { ($0.autoHeadphone ? 0 : 1, $0.name) < ($1.autoHeadphone ? 0 : 1, $1.name) }
        refresh()

        // Animação quando um fone acabou de virar a saída de áudio.
        let uid = device != kAudioObjectUnknown ? Audio.uid(device) : ""
        if isHeadphone && uid != lastHeadUID {
            DispatchQueue.main.async { HeadphoneBattery.shared.refresh(force: true) }
        }
        if isHeadphone && uid != lastHeadUID && didInitialLoad && Prefs.connectAnimation {
            showConnectAnimation()
        }
        lastHeadUID = isHeadphone ? uid : ""
        didInitialLoad = true
    }

    private func watch(_ id: AudioObjectID, add: Bool) {
        var addrs = [
            Audio.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput),
            Audio.addr(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput),
        ]
        for ch: UInt32 in [0, 1, 2] { addrs.append(Audio.addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, ch)) }
        for var a in addrs where AudioObjectHasProperty(id, &a) {
            if add { AudioObjectAddPropertyListenerBlock(id, &a, audioQueue, devListener) }
            else { AudioObjectRemovePropertyListenerBlock(id, &a, audioQueue, devListener) }
        }
    }

    // MARK: Teclas de mídia (quando o app substitui o aviso do macOS)

    var isMuted: Bool {
        device != kAudioObjectUnknown && Audio.uint32(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput) == 1
    }

    private func setMute(_ on: Bool) {
        var a = Audio.addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var v: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    /// Sobe/desce o volume respeitando o limite seguro nos fones.
    func stepVolume(_ delta: Float) {
        guard device != kAudioObjectUnknown, let v = Audio.volume(device) else { return }
        if isMuted { setMute(false) }
        var nv = max(0, min(1, (v + delta)))
        var limited = false
        if enabled && isHeadphone && nv > limit + 0.001 { nv = limit; limited = delta > 0 }
        Audio.setVolume(device, nv)
        volume = nv
        HUDModel.shared.show(.volume, nv, limited: limited)
    }

    func toggleMute() {
        guard device != kAudioObjectUnknown else { return }
        let m = !isMuted
        setMute(m)
        HUDModel.shared.show(.volume, m ? 0 : volume)
    }

    func showConnectAnimation() {
        IslandController.shared.showConnect(name: isHeadphone ? deviceName : "QCY MeloBuds Pro", sound: Prefs.connectSound)
    }

    private func flashClamp() {
        HUDModel.shared.show(.volume, limit, limited: true)
        justClamped = true
        clampWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.justClamped = false }
        clampWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    /// Lê o estado atual e aplica o limite.
    func refresh() {
        let ok = device != kAudioObjectUnknown
        let uid = ok ? Audio.uid(device) : ""
        let name = ok ? Audio.name(device) : "Nenhum"
        let head = ok && (overrides[uid] ?? Audio.looksLikeHeadphones(device))
        if deviceUID != uid { deviceUID = uid }
        if deviceName != name { deviceName = name }
        if isHeadphone != head { isHeadphone = head }
        syncRule()
        enforce()
    }

    private func enforce() {
        guard device != kAudioObjectUnknown, var v = Audio.volume(device) else {
            if hasVolume { hasVolume = false }
            return
        }
        if enabled && isHeadphone && v > limit + 0.005 {
            Audio.setVolume(device, limit)
            v = limit
            flashClamp()
        }
        if !hasVolume { hasVolume = true }
        if abs(volume - v) > 0.001 {
            // aviso na ilha quando o volume muda (não ao trocar de dispositivo)
            if didInitialLoad && Date().timeIntervalSince(lastDeviceChange) > 1.2 && !justClamped {
                let atLimit = enabled && isHeadphone && v >= limit - 0.005
                HUDModel.shared.show(.volume, v, limited: atLimit && v > volume)
            }
            volume = v
        }
    }
}

// MARK: - Componentes visuais

/// Ícone quadrado colorido, igual ao da barra lateral dos Ajustes.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
    }
}

struct HeroHeader: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            SettingsIcon(symbol: symbol, color: color, size: 56)
            Text(L(title)).font(.title3.bold())
            Text(L(text)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

struct LimitSlider: View {
    @ObservedObject var m = AudioMonitor.shared
    var body: some View {
        Slider(value: Binding(get: { Double(m.limit) }, set: { m.limit = Float($0) }), in: 0.1...1, step: 0.05) {
            EmptyView()
        } minimumValueLabel: {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
        } maximumValueLabel: {
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
        .labelsHidden()
    }
}

// MARK: - Janela de Ajustes

enum Pane: String, CaseIterable, Identifiable {
    case geral, recursos, ilha, protecao, dispositivos, saude
    var id: Self { self }
    var title: String {
        switch self {
        case .geral: return L("Geral")
        case .recursos: return L("Recursos")
        case .ilha: return L("Ilha")
        case .protecao: return L("Proteção Auditiva")
        case .dispositivos: return L("Dispositivos")
        case .saude: return L("Saúde Auditiva")
        }
    }
    var symbol: String {
        switch self {
        case .geral: return "gearshape.fill"
        case .recursos: return "square.grid.2x2.fill"
        case .ilha: return "capsule.fill"
        case .protecao: return "shield.lefthalf.filled"
        case .dispositivos: return "headphones"
        case .saude: return "ear.fill"
        }
    }
    var color: Color {
        switch self {
        case .geral: return .gray
        case .recursos: return .orange
        case .ilha: return .indigo
        case .protecao: return .green
        case .dispositivos: return .blue
        case .saude: return .pink
        }
    }
}

struct SettingsView: View {
    @State private var pane: Pane? = .geral
    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label { Text(p.title) } icon: { SettingsIcon(symbol: p.symbol, color: p.color) }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            Group {
                switch pane ?? .geral {
                case .geral: GeneralPane()
                case .recursos: FeaturesPane()
                case .ilha: IslandPane()
                case .protecao: ProtectionPane()
                case .dispositivos: DevicesPane()
                case .saude: HealthPane()
                }
            }
            .navigationTitle((pane ?? .geral).title)
        }
        .frame(minWidth: 680, minHeight: 500)
    }
}

// MARK: - Recursos (cada função liga e desliga, como uma lojinha)

enum Features {
    private static let d = UserDefaults.standard
    private static func on(_ k: String) -> Bool { d.object(forKey: k) as? Bool ?? true }
    static var music: Bool { on("featureMusic") }
    static var calendar: Bool { on("featureCalendar") }
    static var claude: Bool { on("featureClaude") }
    static var hud: Bool { on("featureHUD") }
    static var tasks: Bool { on("featureTasks") }
    static var timer: Bool { on("featureTimer") }
    static var shelf: Bool { on("featureShelf") }
    static var battery: Bool { on("featureBattery") }
    static var stats: Bool { d.object(forKey: "featureStats") as? Bool ?? false }          // opcional
    static var notifications: Bool { d.object(forKey: "featureNotifications") as? Bool ?? false }   // pede Acessibilidade
}

struct FeatureCard: View {
    let symbol: String, color: Color, title: String, text: String
    @Binding var isOn: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                SettingsIcon(symbol: symbol, color: color).scaleEffect(1.25).frame(width: 30, height: 30)
                Spacer()
                Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text(L(title)).font(.system(size: 13, weight: .semibold))
            Text(L(text)).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isOn ? color.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1))
        .opacity(isOn ? 1 : 0.62)
        .animation(.easeOut(duration: 0.18), value: isOn)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

struct FeaturesPane: View {
    @AppStorage("featureMusic") private var music = true
    @AppStorage("featureCalendar") private var calendar = true
    @AppStorage("enabled") private var protection = true
    @AppStorage("featureClaude") private var claude = true
    @AppStorage("featureHUD") private var hud = true
    @AppStorage("lockScreenWidget") private var lock = true
    @AppStorage("connectAnimation") private var connect = true
    @AppStorage("featureTasks") private var tasks = true
    @AppStorage("featureTimer") private var timer = true
    @AppStorage("featureShelf") private var shelf = true
    @AppStorage("featureBattery") private var battery = true
    @AppStorage("featureStats") private var stats = false
    @AppStorage("featureNotifications") private var notifs = false
    @AppStorage("shelfScreenshots") private var shelfShots = true
    @AppStorage("shelfFolder") private var shelfFolder = ""
    @State private var axTrusted = AXIsProcessTrusted()
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Escolha o que a ilha faz. Desligue o que você não usa: o app fica mais leve e o notch mais limpo."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                LazyVGrid(columns: cols, spacing: 12) {
                    FeatureCard(symbol: "music.note", color: .pink, title: "Música",
                                text: "Capa, controles e fila do Spotify e do app Música. Ondinhas no notch enquanto toca.", isOn: $music)
                    FeatureCard(symbol: "calendar", color: .red, title: "Calendário",
                                text: "Data e próximos compromissos quando nada está tocando.", isOn: $calendar)
                    FeatureCard(symbol: "shield.lefthalf.filled", color: .green, title: "Proteção auditiva",
                                text: "Limita o volume nos fones para não machucar seus ouvidos.", isOn: $protection)
                    FeatureCard(symbol: "speaker.wave.2.fill", color: .blue, title: "Avisos de volume e brilho",
                                text: "O aviso sai do notch como uma gota em vez do quadrado do macOS.", isOn: $hud)
                    FeatureCard(symbol: "sparkle", color: .orange, title: "Claude Code",
                                text: "Mostra o que o Claude está fazendo e avisa quando ele espera sua resposta.", isOn: $claude)
                    FeatureCard(symbol: "lock.fill", color: .indigo, title: "Tela de bloqueio",
                                text: "Música e bateria dos fones acima da sua foto, como no iPhone.", isOn: $lock)
                    FeatureCard(symbol: "airpods.gen3", color: .teal, title: "Animação de conexão",
                                text: "Os fones aparecem girando no notch quando conectam.", isOn: $connect)
                    FeatureCard(symbol: "checklist", color: .yellow, title: "Tarefas",
                                text: "Suas tarefas do app Lembretes: marque como feita ou crie uma nova direto no notch.", isOn: $tasks)
                    FeatureCard(symbol: "timer", color: .orange, title: "Timer",
                                text: "Um timer rápido. Enquanto conta, fica ao lado do notch.", isOn: $timer)
                    FeatureCard(symbol: "tray.full.fill", color: .cyan, title: "Estante",
                                text: "Arraste arquivos até o notch para guardar e arraste de volta para onde quiser. Prints entram sozinhos.", isOn: $shelf)
                    FeatureCard(symbol: "bolt.fill", color: .green, title: "Carregamento e bateria",
                                text: "Aviso ao conectar o carregador e quando a bateria do Mac fica fraca.", isOn: $battery)
                    FeatureCard(symbol: "cpu", color: .purple, title: "Sistema",
                                text: "Uso de CPU, memória e bateria numa aba da ilha. Só mede enquanto a aba está aberta.", isOn: $stats)
                    FeatureCard(symbol: "bell.badge.fill", color: .red, title: "Notificações",
                                text: "As notificações aparecem no notch, como no iPhone. Clique para abrir. Precisa de Acessibilidade.", isOn: $notifs)
                }

                if shelf {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(L("Colocar prints novos na estante"), isOn: $shelfShots)
                            HStack {
                                Text(L("Pasta dos prints")).foregroundStyle(.secondary)
                                Text(Shelf.screenshotFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(L("Escolher…")) { chooseFolder() }
                                if !shelfFolder.isEmpty { Button(L("Usar a do macOS")) { shelfFolder = "" } }
                            }
                            .font(.system(size: 12))
                            Text(L("O app segue a pasta onde o macOS já salva seus prints. Se quiser, escolha outra: nada muda no seu Mac."))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(6)
                    } label: { Text(L("Estante")).font(.system(size: 12, weight: .semibold)) }
                }
                if notifs && !axTrusted {
                    GroupBox {
                        HStack {
                            Text(L("As notificações precisam da permissão de Acessibilidade.")).font(.system(size: 12))
                            Spacer()
                            Button(L("Abrir Acessibilidade")) {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .padding(20)
        }
        .onChange(of: music) { _, _ in NowPlaying.shared.featureChanged() }
        .onChange(of: claude) { _, on in ClaudeActivity.shared.paused = !on }
        .onChange(of: shelf) { _, _ in Shelf.shared.watchScreenshots() }
        .onChange(of: shelfShots) { _, _ in Shelf.shared.watchScreenshots() }
        .onChange(of: shelfFolder) { _, _ in Shelf.shared.watchScreenshots() }
        .onChange(of: notifs) { _, on in
            if on { MediaKeys.shared.requestAccessibility() }
            NotificationMirror.shared.start()
        }
        .onChange(of: timer) { _, on in if !on { TimerModel.shared.reset() } }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            let t = AXIsProcessTrusted()
            if t && !axTrusted { NotificationMirror.shared.start() }
            axTrusted = t
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.directoryURL = Shelf.screenshotFolder
        p.prompt = L("Escolher")
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { shelfFolder = u.path }
    }
}

struct GeneralPane: View {
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                HeroHeader(symbol: "capsule.fill", color: .indigo, title: "Oh My Notch!",
                           text: "Transforma o notch numa ilha dinâmica: música, agenda, fones, avisos de volume e brilho, e protege sua audição nos fones.")
            }
            Section {
                Toggle("Abrir ao ligar o Mac", isOn: $loginOn)
                    .onChange(of: loginOn) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            loginOn = SMAppService.mainApp.status == .enabled
                        }
                    }
            } footer: {
                if let e = loginError { Text(e).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }
}

struct IslandPane: View {
    @ObservedObject var m = AudioMonitor.shared
    @AppStorage("liquidGlass") private var liquidGlass = true
    @AppStorage("lockScreenWidget") private var lockScreenWidget = true
    @AppStorage("connectAnimation") private var connectAnimation = true
    @AppStorage("connectSound") private var connectSound = true
    @AppStorage("musicClick") private var musicClick = "expand"
    @AppStorage("islandScreen") private var islandScreen = "follow"
    @AppStorage("replaceSystemHUD") private var replaceHUD = true
    @State private var axTrusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                Toggle("Liquid Glass", isOn: $liquidGlass)
            } footer: {
                Text("As pontas e a ilha aberta ficam em vidro; a parte do notch físico continua preta.")
            }
            Section {
                Toggle("Substituir os avisos de volume e brilho do macOS", isOn: $replaceHUD)
                    .onChange(of: replaceHUD) { _, on in
                        if on { MediaKeys.shared.start(prompt: true) } else { MediaKeys.shared.stop() }
                        axTrusted = AXIsProcessTrusted()
                    }
                if replaceHUD && !axTrusted {
                    LabeledContent("Precisa da permissão de Acessibilidade") {
                        Button("Permitir…") {
                            MediaKeys.shared.start(prompt: true)
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                    }
                }
            } header: {
                Text("Avisos de volume e brilho")
            } footer: {
                Text("O app aplica as teclas de volume, mudo e brilho e mostra só o aviso do notch, sem o aviso padrão do macOS. O volume continua respeitando o limite seguro.")
            }
            Section {
                Picker("Mostrar a ilha", selection: $islandScreen) {
                    Text("Na tela onde está o mouse").tag("follow")
                    Text("Só na tela com notch").tag("notch")
                }
            } header: {
                Text("Telas")
            } footer: {
                Text("Em monitores sem notch, a ilha aparece como uma pílula no topo central.")
            }
            Section("Música") {
                Picker("Ao clicar na capa", selection: $musicClick) {
                    Text("Expandir a música").tag("expand")
                    Text("Abrir o app que está tocando").tag("open")
                }
            }
            Section("Ao conectar um fone") {
                Toggle("Mostrar animação", isOn: $connectAnimation)
                Toggle("Tocar som", isOn: $connectSound).disabled(!connectAnimation)
            }
            Section {
                Toggle("Widget na tela de bloqueio", isOn: $lockScreenWidget)
            } footer: {
                Text("Mostra a música e o fone acima da sua foto. Usa um recurso interno do macOS e vale depois de reabrir o app.")
            }
            Section("Pré-visualizar") {
                LabeledContent("Fone conectando") { Button("Testar") { m.showConnectAnimation() } }
                LabeledContent("Aviso de volume") { Button("Testar") { HUDModel.shared.show(.volume, m.volume) } }
                LabeledContent("Limite atingido") { Button("Testar") { HUDModel.shared.show(.volume, m.limit, limited: true) } }
            }
        }
        .formStyle(.grouped)
    }
}

struct ProtectionPane: View {
    @ObservedObject var m = AudioMonitor.shared
    var body: some View {
        Form {
            Section {
                Toggle("Proteção auditiva", isOn: $m.enabled)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Limite de volume nos fones")
                        Spacer()
                        Text("\(m.limitPercent)%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    LimitSlider()
                }
                .disabled(!m.enabled)
            } footer: {
                Text("Se o volume passar do limite, ele volta na hora e a ilha avisa em laranja. Nos alto-falantes o volume fica livre.")
            }
        }
        .formStyle(.grouped)
    }
}

struct DevicesPane: View {
    @ObservedObject var m = AudioMonitor.shared
    var body: some View {
        let status = protectionStatus(m)
        Form {
            Section("Saída atual") {
                LabeledContent {
                    Text(status.text).foregroundStyle(m.isLimiting ? Color.green : .secondary)
                } label: {
                    Label { Text(m.deviceName) } icon: {
                        SettingsIcon(symbol: m.isHeadphone ? "headphones" : "hifispeaker.fill", color: m.isLimiting ? .green : .gray)
                    }
                }
                if m.hasVolume {
                    LabeledContent("Volume atual") { Text(percent(m.volume)).monospacedDigit() }
                }
            }
            Section {
                ForEach(m.devices) { d in
                    Toggle(isOn: Binding(get: { m.shouldLimit(d) }, set: { m.setLimit(d, $0) })) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name)
                                Text(d.id == m.deviceUID ? LF("%@ · Em uso", d.kind) : d.kind)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            SettingsIcon(symbol: d.symbol, color: d.autoHeadphone ? .blue : .gray)
                        }
                    }
                }
            } header: {
                Text("Limitar volume em")
            } footer: {
                Text("Fones Bluetooth (AirPods, Galaxy Buds, QCY…) e fones com fio são detectados sozinhos. Desligue aqui se for uma caixa de som Bluetooth.")
            }
        }
        .formStyle(.grouped)
    }
}

struct HealthPane: View {
    @ObservedObject var m = AudioMonitor.shared
    var body: some View {
        Form {
            Section {
                HeroHeader(symbol: "ear.fill", color: .pink, title: "Saúde Auditiva",
                           text: "Ouvir som alto por muito tempo pode causar perda auditiva permanente. A OMS recomenda a regra 60/60: até 60% do volume, por até 60 minutos seguidos.")
            }
            Section("Níveis de referência") {
                LabeledContent { Text("Uso prolongado").foregroundStyle(.secondary) } label: {
                    Label { Text("Até 60%") } icon: { SettingsIcon(symbol: "checkmark", color: .green) }
                }
                LabeledContent { Text("Faça pausas").foregroundStyle(.secondary) } label: {
                    Label { Text("60% a 80%") } icon: { SettingsIcon(symbol: "clock.fill", color: .orange) }
                }
                LabeledContent { Text("Evite").foregroundStyle(.secondary) } label: {
                    Label { Text("Acima de 80%") } icon: { SettingsIcon(symbol: "exclamationmark", color: .red) }
                }
            }
            Section {
                Button("Usar 60% (recomendado)") { m.limit = 0.6 }
            } footer: {
                Text("A porcentagem vale para o volume do Mac. O nível real em decibéis muda um pouco de um fone para outro.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) var shared: AppDelegate!
    private var window: NSWindow?

    override init() { super.init(); AppDelegate.shared = self }

    func applicationWillTerminate(_ notification: Notification) { UniversalMedia.shared.stop() }

    func applicationDidFinishLaunching(_ n: Notification) {
        migrateFromVolumeSeguro()
        _ = AudioMonitor.shared
        IslandController.shared.start()
        NowPlaying.shared.start()
        HeadphoneBattery.shared.start()
        LockScreenController.shared.start()
        BrightnessMonitor.shared.start()
        ClaudeActivity.shared.start()
        ClaudeActivity.shared.paused = !Features.claude
        PowerMonitor.shared.start()
        Shelf.shared.watchScreenshots()
        NotificationMirror.shared.start()
        MediaKeys.shared.start(prompt: false)
        if let i = CommandLine.arguments.firstIndex(of: "--hud-snapshot"), i + 1 < CommandLine.arguments.count {
            renderHUDSnapshot(to: CommandLine.arguments[i + 1]); exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--lock-snapshot"), i + 1 < CommandLine.arguments.count {
            renderLockSnapshot(to: CommandLine.arguments[i + 1]); exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let mode = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : "open"
            renderIslandSnapshot(to: CommandLine.arguments[i + 1], mode: mode); exit(0)
        }
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AudioMonitor.shared.showConnectAnimation() }
        }
        // Na primeira vez, registra para abrir sozinho ao ligar o Mac.
        if !Prefs.didSetupLogin {
            try? SMAppService.mainApp.register()
            Prefs.didSetupLogin = true
            showSettings()
        }
    }

    /// Traz as preferências do app antigo (Volume Seguro) uma única vez.
    private func migrateFromVolumeSeguro() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromVolumeSeguro"),
              let old = UserDefaults(suiteName: "local.volumeseguro") else { return }
        for k in ["enabled", "limit", "overrides", "connectAnimation", "connectSound", "liquidGlass", "lockScreenWidget"] {
            if let v = old.object(forKey: k) { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "migratedFromVolumeSeguro")
    }

    // Abrir o app de novo (Spotlight/Launchpad/Aplicativos) mostra os Ajustes.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings(); return true
    }

    func showSettings() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 715, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Oh My Notch!"
            w.toolbarStyle = .unified
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.setContentSize(NSSize(width: 715, height: 540))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct OhMyNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Sem ícone na barra de menus: tudo acontece na ilha do notch.
    // Os Ajustes abrem ao reabrir o app (Spotlight) ou pela engrenagem na ilha.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
