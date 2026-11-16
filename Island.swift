// Ilha no notch, no estilo Dynamic Island.

import SwiftUI
import AppKit
import Combine

// MARK: - Bateria (via system_profiler)

struct BatteryInfo {
    var main: Int?, left: Int?, right: Int?, caseLevel: Int?
    var isEmpty: Bool { main == nil && left == nil && right == nil && caseLevel == nil }
}

enum Battery {
    static func fetch(name: String, completion: @escaping (BatteryInfo) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result = BatteryInfo()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let first = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
                   let connected = first["device_connected"] as? [[String: Any]] {
                    var candidates: [(exact: Bool, info: BatteryInfo)] = []
                    for entry in connected {
                        for (n, v) in entry {
                            guard let d = v as? [String: Any] else { continue }
                            let exact = n == name
                            guard exact || n.hasPrefix(name) || name.hasPrefix(n) else { continue }
                            func lv(_ k: String) -> Int? {
                                (d[k] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
                            }
                            let info = BatteryInfo(main: lv("device_batteryLevelMain"), left: lv("device_batteryLevelLeft"),
                                                   right: lv("device_batteryLevelRight"), caseLevel: lv("device_batteryLevelCase"))
                            if !info.isEmpty { candidates.append((exact, info)) }
                        }
                    }
                    result = (candidates.first { $0.exact } ?? candidates.first)?.info ?? BatteryInfo()
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

func firstSymbol(_ names: [String], fallback: String = "headphones") -> String {
    names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? fallback
}


// MARK: - Imagem do fone

/// Imagem própria do fone (Resources/Devices/<nome>.png ou
/// ~/Library/Application Support/VolumeSeguro/Devices/<nome>.png).
func deviceImage(for name: String) -> NSImage? {
    let file = name.lowercased() + ".png"
    var urls: [URL] = []
    if let r = Bundle.main.resourceURL { urls.append(r.appendingPathComponent("Devices/" + file)) }
    if let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        urls.append(sup.appendingPathComponent("OhMyNotch/Devices/" + file))
        urls.append(sup.appendingPathComponent("VolumeSeguro/Devices/" + file))
    }
    for u in urls { if let img = NSImage(contentsOf: u) { return img } }
    return nil
}

func budsSymbol(for name: String) -> String {
    let n = name.lowercased()
    if n.contains("airpods max") { return firstSymbol(["airpods.max", "airpodsmax"]) }
    if n.contains("airpods pro") { return firstSymbol(["airpods.pro", "airpodspro", "earbuds"]) }
    if n.contains("airpods") { return firstSymbol(["airpods", "earbuds"]) }
    if n.contains("buds") || n.contains("pods") || n.contains("qcy") { return firstSymbol(["earbuds", "airpods"]) }
    return "headphones"
}

extension NSImage {
    /// Metade esquerda ou direita (para separar os dois fones).
    func half(left: Bool) -> NSImage? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width / 2
        guard let c = cg.cropping(to: CGRect(x: left ? 0 : cg.width - w, y: 0, width: w, height: cg.height)) else { return nil }
        return NSImage(cgImage: c, size: NSSize(width: w, height: cg.height))
    }
}

var reduceMotion: Bool { DS.Motion.reduced }

// MARK: - Bateria do fone atual

final class HeadphoneBattery: ObservableObject {
    static let shared = HeadphoneBattery()
    @Published var info = BatteryInfo()
    private var lastFetch = Date.distantPast
    private var lastName = ""

    var level: Int? {
        if let m = info.main { return m }
        let p = [info.left, info.right].compactMap { $0 }
        return p.isEmpty ? nil : p.min()
    }

    func start() {
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh(force: true) }
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        let m = AudioMonitor.shared
        guard m.isHeadphone else { info = BatteryInfo(); lastName = ""; return }
        let name = m.deviceName
        guard force || name != lastName || Date().timeIntervalSince(lastFetch) > 60 else { return }
        lastName = name; lastFetch = Date()
        Battery.fetch(name: name) { [weak self] i in self?.info = i }
    }
}

// MARK: - Modelo da ilha

enum IslandMode: Equatable {
    case closed     // do tamanho do notch (invisível)
    case home       // ao passar o mouse: música ou calendário
    case headphone  // ao clicar no fone do cantinho: status do fone
    case connect    // fone acabou de conectar
    case compact    // "asas" ao lado do notch (fone conectou)
    case live       // música tocando: capa + equalizador, sempre visível
    case claude     // Claude Code agindo: anel de bolinhas + o que está fazendo
    case claudeThink // Claude Code pensando: cúpula com fita líquida
    case music      // música expandida: capa grande, progresso, controles e fila
    case timer      // timer rodando: asas com a contagem
    case charging   // carregador conectado: asas com raio e porcentagem
    case alert      // aviso rápido: timer acabou, print salvo, bateria fraca, notificação

    /// Estados "parados" (a ilha não está aberta pelo mouse)
    var isIdleLike: Bool { [.closed, .live, .compact, .claude, .claudeThink, .timer, .charging].contains(self) }
}

final class IslandModel: ObservableObject {
    @Published var mode: IslandMode = .closed
    @Published var contentVisible = false
    @Published var growing = true
    /// false enquanto a forma se transforma: só preto sólido; o vidro aparece quando assenta
    @Published var glassReady = true
    @Published var notch = CGSize(width: 200, height: 32)

    // Fone conectado (para connect/compact); bateria vem de HeadphoneBattery
    @Published var connectName = ""

    // Abas do painel, aviso atual e arrastar arquivos
    @Published var tab: HomeTab = .home
    /// Segunda atividade ao mesmo tempo: vira uma bolinha separada ao lado (como no iPhone)
    @Published var secondary: LiveKind?
    @Published var alert: IslandAlert?
    @Published var dropTargeted = false
    func select(_ t: HomeTab) { withAnimation(DS.Motion.swap) { tab = t } }

    var hasNotch: Bool { notch.height > 0 }

    static let connectWidth: CGFloat = 340
    static let claudeWing: CGFloat = 96     // compacto: não cobrir os menus da barra

    /// Largura a mais na asa direita quando há uma 2ª atividade (o ícone dela fica no fim da asa).
    static let secondaryWidth: CGFloat = 32
    func extra(_ m: IslandMode) -> CGFloat {
        secondary != nil && [.claude, .timer, .live].contains(m) ? Self.secondaryWidth : 0
    }
    func size(_ m: IslandMode) -> CGSize {
        let b = baseSize(m)
        return CGSize(width: b.width + extra(m), height: b.height)
    }
    func baseSize(_ m: IslandMode) -> CGSize {
        let h = max(notch.height, 32)
        switch m {
        case .closed:  return CGSize(width: notch.width, height: notch.height)
        case .home, .headphone: return CGSize(width: DS.Metric.panelWidth, height: h + 84)
        case .connect: return CGSize(width: Self.connectWidth, height: h + 94)
        case .compact, .live: return CGSize(width: notch.width + 2 * DS.Metric.wing, height: h)
        case .claude: return CGSize(width: notch.width + 2 * (Self.claudeWing + 10), height: h)
        case .claudeThink: return CGSize(width: notch.width + 16, height: h + 48)
        case .timer: return CGSize(width: notch.width + 2 * 58, height: h)
        case .charging: return CGSize(width: notch.width + 2 * 62, height: h)
        case .alert: return CGSize(width: 360, height: h + 62)
        case .music:
            let rows = min(4, NowPlaying.shared.upNext.count)
            let extra: CGFloat = rows > 0 ? 18 + CGFloat(rows) * 30 : (NowPlaying.shared.app == "Spotify" ? 4 : 0)
            return CGSize(width: DS.Metric.panelWidth, height: h + 150 + extra)
        }
    }
    func radii(_ m: IslandMode) -> (top: CGFloat, bottom: CGFloat) {
        switch m {
        case .closed:  return DS.Metric.closed
        case .compact, .live, .claude, .timer, .charging: return DS.Metric.wings
        case .claudeThink: return (10, 46)
        case .home, .headphone, .connect, .music, .alert: return DS.Metric.open
        }
    }
}

// MARK: - Várias atividades ao mesmo tempo

enum LiveKind: Equatable { case claude, timer, music }

/// Ícone da 2ª atividade, no fim da asa direita.
struct SecondaryIcon: View {
    let kind: LiveKind
    @ObservedObject var np = NowPlaying.shared
    @ObservedObject var t = TimerModel.shared
    @ObservedObject var c = ClaudeActivity.shared
    var body: some View {
        Group {
            switch kind {
            case .music:
                Artwork(image: np.artwork, size: 18).id(np.title)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .timer:
                ZStack {
                    Circle().stroke(Color.orange.opacity(0.25), lineWidth: 2.2)
                    Circle().trim(from: 0, to: t.progress)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: t.running ? "timer" : "pause.fill").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.orange)
                }
                .frame(width: 16, height: 16)
            case .claude:
                if c.phase == .waiting {
                    Image(systemName: "exclamationmark.bubble.fill").font(DS.Font.icon(11)).foregroundStyle(ClaudePalette.accent)
                } else if c.phase == .done {
                    Image(systemName: "checkmark").font(DS.Font.icon(11)).foregroundStyle(DS.Palette.safe)
                } else {
                    ClaudeDots(size: 15)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { IslandController.shared.bubbleTapped(kind) }
        .help(kind == .music ? np.title : (kind == .timer ? TimerModel.format(t.remaining) : "Claude"))
    }
}

// MARK: - Forma

struct NotchShape: InsettableShape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var insetAmount: CGFloat = 0

    /// Encolhe pelas laterais e pela base; o topo continua colado no notch.
    func inset(by amount: CGFloat) -> NotchShape {
        var c = self; c.insetAmount += amount; return c
    }
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let i = insetAmount
        let r = CGRect(x: rect.minX + i, y: rect.minY, width: max(0, rect.width - 2 * i), height: max(0, rect.height - i))
        let t = topRadius, b = max(0, min(bottomRadius - i * 0.6, r.height / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Fones (inclinação leve + reflexo de luz)

struct BudImage: View {
    let image: NSImage
    var gleam: CGFloat
    var body: some View {
        let img = Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        img.overlay {
            GeometryReader { g in
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.7), .white.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 0.35, height: g.size.height * 1.6)
                    .rotationEffect(.degrees(22))
                    .offset(x: (gleam * 2.4 - 0.7) * g.size.width, y: -g.size.height * 0.3)
            }
            .mask(img)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }
}

/// Os dois fones. `animated`: balanço + reflexo. `swingIn`: entra inclinando em 3D uma vez.
struct BudsView: View {
    let name: String
    var animated = true
    var swingIn = false
    @State private var tilt = false
    @State private var float = false
    @State private var gleam: CGFloat = 0
    @State private var arrived = false

    var body: some View {
        Group {
            if let img = deviceImage(for: name), let l = img.half(left: true), let r = img.half(left: false) {
                HStack(spacing: 2) {
                    BudImage(image: l, gleam: gleam)
                        .rotation3DEffect(.degrees(tilt ? 9 : -9), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                        .rotationEffect(.degrees(tilt ? -2 : 2))
                    BudImage(image: r, gleam: max(0, gleam - 0.08))
                        .rotation3DEffect(.degrees(tilt ? -9 : 9), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                        .rotationEffect(.degrees(tilt ? 2 : -2))
                }
                .shadow(color: .white.opacity(0.22), radius: 4)
            } else {
                Image(systemName: budsSymbol(for: name)).resizable().scaledToFit()
                    .symbolRenderingMode(.hierarchical).foregroundStyle(DS.Palette.primary)
                    .padding(8)
                    .rotationEffect(.degrees(tilt ? 4 : -4))
            }
        }
        .offset(y: float ? -2.5 : 2.5)
        .rotation3DEffect(.degrees(arrived ? 0 : 70), axis: (x: 0.2, y: 1, z: 0), perspective: 0.6)
        .onAppear {
            if swingIn && !DS.Motion.reduced {
                withAnimation(.spring(duration: 0.9, bounce: 0.35)) { arrived = true }
            } else { arrived = true }
            guard animated, !DS.Motion.reduced else { return }
            withAnimation(DS.Motion.ambient(3.6)) { tilt = true }
            withAnimation(DS.Motion.ambient(2.8)) { float = true }
            withAnimation(.easeInOut(duration: 1.4).delay(0.5).repeatForever(autoreverses: false)) { gleam = 1 }
        }
    }
}

// MARK: - Barra de volume com a marca do limite

struct SafeVolumeBar: View {
    let volume: Float
    let limit: Float
    let limiting: Bool
    var tint: Color = DS.Palette.primary
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.track)
                if limiting {
                    Capsule().fill(DS.Palette.danger.opacity(0.2))
                        .frame(width: g.size.width * CGFloat(1 - limit))
                        .offset(x: g.size.width * CGFloat(limit))
                }
                Capsule().fill(tint)
                    .frame(width: max(height, g.size.width * CGFloat(volume)))
                if limiting {
                    Capsule().fill(DS.Palette.safe)
                        .frame(width: 2.5, height: height + 6)
                        .offset(x: g.size.width * CGFloat(limit) - 1.25)
                }
            }
            .animation(DS.Motion.swap, value: volume)
            .animation(DS.Motion.swap, value: limit)
        }
        .frame(height: height)
    }
}

/// Texto de status de proteção, igual em todo lugar.
func protectionStatus(_ m: AudioMonitor) -> (text: String, color: Color) {
    if !m.isHeadphone { return (L("Alto-falante · sem limite"), DS.Palette.secondary) }
    if !m.enabled { return (L("Proteção desligada"), DS.Palette.secondary) }
    return (LF("Protegido · limite %d%%", m.limitPercent), DS.Palette.safe)
}

// MARK: - Painel do fone (clicar no fone do cantinho)

struct HeadphoneContent: View {
    @ObservedObject var m = AudioMonitor.shared
    var body: some View {
        let status = protectionStatus(m)
        HStack(spacing: 14) {
            Group {
                if m.isHeadphone { BudsView(name: m.deviceName) }
                else {
                    Image(systemName: "hifispeaker.fill").resizable().scaledToFit()
                        .foregroundStyle(DS.Palette.secondary).padding(12)
                }
            }
            .frame(width: 76, height: 58)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(m.deviceName).font(DS.Font.headline).foregroundStyle(DS.Palette.primary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        IconButton(symbol: "gearshape.fill", size: 10, help: "Ajustes") { AppDelegate.shared.showSettings() }
                    }
                    Text(status.text).font(DS.Font.body).foregroundStyle(status.color)
                }
                HStack(spacing: 8) {
                    SafeVolumeBar(volume: m.volume, limit: m.limit, limiting: m.isLimiting)
                    Text(percent(m.volume)).font(DS.Font.value).foregroundStyle(DS.Palette.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, DS.Metric.panelPadding)
        .padding(.bottom, 14)
    }
}

// MARK: - Início (passar o mouse): música ou calendário

struct HomeContent: View {
    @ObservedObject var np = NowPlaying.shared
    var body: some View {
        Group {
            if np.hasTrack { MusicView() }
            else if Features.calendar { CalendarView() }
            else { HeadphoneContent() }
        }
        .padding(.horizontal, DS.Metric.panelPadding)
        .padding(.bottom, 14)
    }
}

struct MusicView: View {
    @ObservedObject var np = NowPlaying.shared
    var body: some View {
        HStack(spacing: 12) {
            Button {
                if UserDefaults.standard.string(forKey: "musicClick") == "open" { np.openPlayingApp() }
                else { IslandController.shared.openMusic() }
            } label: {
                Artwork(image: np.artwork, size: 56)
                    .scaleEffect(np.isPlaying ? 1 : 0.92)
                    .animation(DS.Motion.pop, value: np.isPlaying)
            }
            .buttonStyle(.plain)
            .help(UserDefaults.standard.string(forKey: "musicClick") == "open" ? "Abrir o app" : "Expandir a música")
            VStack(alignment: .leading, spacing: 2) {
                Text(np.title).font(DS.Font.headline).foregroundStyle(DS.Palette.primary).lineLimit(1)
                Text(np.artist).font(DS.Font.body).foregroundStyle(DS.Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            MusicControls()
        }
    }
}

// MARK: - Música expandida

struct MusicExpanded: View {
    @ObservedObject var np = NowPlaying.shared
    @State private var scrubbing: Double? = nil

    func time(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded()); return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Button { np.openPlayingApp() } label: {
                    Artwork(image: np.artwork, size: 104)
                        .shadow(color: np.accent.opacity(0.45), radius: 14, y: 6)
                }
                .buttonStyle(.plain).help("Abrir o app")
                VStack(alignment: .leading, spacing: 4) {
                    Text(np.title).font(DS.Font.title).foregroundStyle(DS.Palette.primary).lineLimit(2)
                    Text(np.artist).font(DS.Font.body).foregroundStyle(DS.Palette.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    // progresso (arraste para pular)
                    let frac = np.duration > 0 ? (scrubbing ?? np.position / np.duration) : 0
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.Palette.track)
                            Capsule().fill(DS.Palette.primary).frame(width: max(4, g.size.width * frac))
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in scrubbing = min(1, max(0, v.location.x / g.size.width)) }
                            .onEnded { _ in if let f = scrubbing { np.seek(to: f) }; scrubbing = nil })
                    }
                    .frame(height: 5)
                    HStack {
                        Text(time(np.duration * frac))
                        Spacer()
                        Text("-" + time(max(0, np.duration - np.duration * frac)))
                    }
                    .font(DS.Font.caption).monospacedDigit().foregroundStyle(DS.Palette.tertiary)
                    HStack(spacing: 18) {
                        Spacer()
                        IconButton(symbol: "backward.fill", size: 16, help: "Anterior") { np.previous() }
                        IconButton(symbol: np.isPlaying ? "pause.fill" : "play.fill", size: 24, help: "Tocar/Pausar") { np.playPause() }
                        IconButton(symbol: "forward.fill", size: 16, help: "Próxima") { np.next() }
                        Spacer()
                    }
                }
                .frame(height: 104)
            }
            if !np.upNext.isEmpty {
                Text("A seguir").font(DS.Font.caption).foregroundStyle(DS.Palette.tertiary)
                VStack(spacing: 2) {
                    ForEach(Array(np.upNext.prefix(4).enumerated()), id: \.offset) { i, t in
                        UpNextRow(text: t) { np.playUpNext(i) }
                    }
                }
            } else if np.app == "Spotify" {
                Button { np.openPlayingApp() } label: {
                    Label("Ver a fila no Spotify", systemImage: "list.bullet")
                        .font(DS.Font.body).foregroundStyle(DS.Palette.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(DS.Palette.track))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Metric.panelPadding)
        .padding(.bottom, 16)
    }
}

struct UpNextRow: View {
    let text: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: hover ? "play.fill" : "music.note").font(.system(size: 10))
                    .foregroundStyle(DS.Palette.tertiary).frame(width: 14)
                Text(text).font(DS.Font.body).foregroundStyle(hover ? DS.Palette.primary : DS.Palette.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? DS.Palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Motion.hover) { hover = h } }
    }
}

struct MusicControls: View {
    @ObservedObject var np = NowPlaying.shared
    var body: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "backward.fill", size: 13, help: "Anterior") { np.previous() }
            IconButton(symbol: np.isPlaying ? "pause.fill" : "play.fill", size: 19, help: "Tocar/Pausar") { np.playPause() }
            IconButton(symbol: "forward.fill", size: 13, help: "Próxima") { np.next() }
        }
    }
}

struct CalendarView: View {
    @ObservedObject var cal = CalendarFeed.shared
    private let now = Date()

    func fmt(_ d: Date, _ f: String) -> String {
        let df = DateFormatter(); df.locale = Locale.current; df.setLocalizedDateFormatFromTemplate(f == "HH:mm" ? "jm" : f)
        return df.string(from: d)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: -2) {
                Text(fmt(now, "EEE").uppercased().replacingOccurrences(of: ".", with: ""))
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.danger)
                Text(fmt(now, "d")).font(DS.Font.display).foregroundStyle(DS.Palette.primary)
                Text(fmt(now, "MMMM")).font(DS.Font.caption).foregroundStyle(DS.Palette.tertiary)
            }
            .frame(width: 64, alignment: .leading)

            Rectangle().fill(DS.Palette.track).frame(width: 1, height: 52)

            VStack(alignment: .leading, spacing: 8) {
                if !cal.authorized {
                    Button { cal.access == .notDetermined ? cal.request() : openPrivacy() } label: {
                        Label("Mostrar sua agenda", systemImage: "calendar.badge.plus")
                            .font(DS.Font.body).foregroundStyle(DS.Palette.secondary)
                    }.buttonStyle(.plain)
                } else if cal.items.isEmpty {
                    Text("Nenhum evento hoje").font(DS.Font.body).foregroundStyle(DS.Palette.secondary)
                } else {
                    ForEach(cal.items.prefix(2)) { e in
                        HStack(spacing: 8) {
                            Capsule().fill(e.color).frame(width: 3, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(DS.Font.headline).foregroundStyle(DS.Palette.primary).lineLimit(1)
                                Text(e.allDay ? L("Dia todo") : "\(fmt(e.start, "HH:mm")) – \(fmt(e.end, "HH:mm"))")
                                    .font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    func openPrivacy() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - Barra de cima: fone no cantinho (anel de bateria) + equalizador

struct HeadphoneBadge: View {
    @ObservedObject var m = AudioMonitor.shared
    @ObservedObject var battery = HeadphoneBattery.shared
    let active: Bool
    @State private var hover = false

    var body: some View {
        Button { IslandController.shared.toggleHeadphone() } label: {
            Group {
                if battery.level != nil {
                    BatteryRing(level: battery.level, size: 26, line: 2.5, pulse: true) {
                        DeviceGlyph(name: m.deviceName, width: 16)
                    }
                } else {
                    DeviceGlyph(name: m.deviceName, width: 20).frame(width: 26, height: 26)
                }
            }
            .background(Circle().fill(active ? DS.Palette.track : (hover ? DS.Palette.hover : .clear)))
            .scaleEffect(hover ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Motion.hover) { hover = h } }
        .help(battery.level.map { LF("Bateria do fone: %d%%", $0) } ?? L("Status do fone"))
    }
}

/// Equalizador em Core Animation (anima no servidor de desenho, quase sem CPU).
struct Equalizer: NSViewRepresentable {
    let playing: Bool
    var color: Color = DS.Palette.safe
    var height: CGFloat = 14

    func makeNSView(context: Context) -> EqView { EqView(height: height) }
    func updateNSView(_ v: EqView, context: Context) {
        v.update(playing: playing && !DS.Motion.reduced, color: NSColor(color))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EqView, context: Context) -> CGSize? {
        CGSize(width: 18, height: height)
    }
}

final class EqView: NSView {
    private var bars: [CALayer] = []
    private let h: CGFloat
    private var playing: Bool?
    private let durations: [CFTimeInterval] = [0.42, 0.33, 0.5, 0.38]
    private let lows: [CGFloat] = [0.3, 0.45, 0.25, 0.4]

    init(height: CGFloat) {
        h = height
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: height))
        wantsLayer = true
        for i in 0..<4 {
            let b = CALayer()
            b.frame = CGRect(x: CGFloat(i) * 5, y: 0, width: 3, height: height)
            b.cornerRadius = 1.5
            b.transform = CATransform3DMakeScale(1, 0.25, 1)
            layer?.addSublayer(b)
            bars.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: h) }

    func update(playing: Bool, color: NSColor) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        bars.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()
        guard playing != self.playing else { return }
        self.playing = playing
        for (i, b) in bars.enumerated() {
            b.removeAnimation(forKey: "eq")
            if playing {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = lows[i]; a.toValue = 1.0
                a.duration = durations[i]
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.timeOffset = Double(i) * 0.11
                a.preferredFrameRateRange = Anim.calm
                b.add(a, forKey: "eq")
            }
        }
    }
}

struct TopBar: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var m = AudioMonitor.shared
    @ObservedObject var np = NowPlaying.shared
    var body: some View {
        HStack(spacing: 8) {
            if model.mode == .home && HomeTab.visible.count > 1 {
                // painel com abas: abas à esquerda, fone e ondinhas à direita
                TabBar(model: model)
                Spacer(minLength: model.notch.width)
                if np.hasTrack { Equalizer(playing: np.isPlaying, color: np.accent) }
                if m.isHeadphone { HeadphoneBadge(active: false) }
            } else {
                if m.isHeadphone { HeadphoneBadge(active: model.mode == .headphone) }
                Spacer(minLength: model.notch.width)
                if np.hasTrack { Equalizer(playing: np.isPlaying, color: np.accent) }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: max(model.notch.height, 32))
    }
}

// MARK: - Fone conectou

struct ConnectContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var m = AudioMonitor.shared
    @ObservedObject var battery = HeadphoneBattery.shared
    @State private var budsIn = false
    @State private var check = 0

    var body: some View {
        HStack(spacing: 12) {
            BudsView(name: model.connectName, swingIn: true)
                .frame(width: 84, height: 66)
                .scaleEffect(budsIn ? 1 : 0.3)
                .opacity(budsIn ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.safe)
                        .symbolEffect(.bounce, value: check)
                    Text("Conectado")
                }
                .font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                Text(model.connectName).font(DS.Font.title).foregroundStyle(DS.Palette.primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if m.enabled {
                    Label("Limite \(m.limitPercent)%", systemImage: "shield.lefthalf.filled")
                        .font(DS.Font.body).foregroundStyle(DS.Palette.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            BatteryRing(level: battery.level, size: 42, line: 4, showsValue: true)
                .opacity(battery.level == nil ? 0 : 1)
                .animation(DS.Motion.pop, value: battery.level)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .onAppear {
            withAnimation(DS.Motion.pick(DS.Motion.pop.delay(0.05))) { budsIn = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { check += 1 }
        }
    }
}

// MARK: - Asas (compacto): fone conectado / música tocando

struct WingsContent<Leading: View, Trailing: View>: View {
    @ObservedObject var model: IslandModel
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: DS.Metric.wing)
            Spacer(minLength: model.notch.width)
            trailing.frame(width: DS.Metric.wing)
        }
        .frame(height: max(model.notch.height, 32))
    }
}

struct CompactContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var battery = HeadphoneBattery.shared
    var body: some View {
        WingsContent(model: model) {
            DeviceGlyph(name: model.connectName, width: 26)
        } trailing: {
            BatteryRing(level: battery.level, size: 18, line: 2.5)
        }
    }
}

struct LiveMusicContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var np = NowPlaying.shared
    var body: some View {
        WingsContent(model: model) {
            Artwork(image: np.artwork, size: 22)
                .id(np.title)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .animation(DS.Motion.pop, value: np.title)
        } trailing: {
            Equalizer(playing: np.isPlaying, color: np.accent, height: 13)
        }
    }
}

// MARK: - Faixa preta do notch físico (fica por cima do vidro, emendando sem costura)

struct NotchBand: View {
    var notchHeight: CGFloat
    var notchWidth: CGFloat
    var body: some View {
        GeometryReader { g in
            let h = max(g.size.height, 1)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: min(1, notchHeight / h)),
                    .init(color: .black.opacity(0), location: min(1, (notchHeight + 8) / h)),
                ], startPoint: .top, endPoint: .bottom))
                .frame(width: min(notchWidth, g.size.width), height: h)
                .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Raiz
// Camadas: (1) só formas de vidro dentro do container líquido (ilha + aviso),
// (2) faixa preta do notch, (3) conteúdo. Conteúdo fora do container para não ficar borrado.

struct IslandRoot: View {
    @ObservedObject var model: IslandModel
    let canvas: CGSize
    @AppStorage("liquidGlass") private var glassOn = true

    var body: some View {
        let s = model.size(model.mode)
        let r = model.radii(model.mode)
        let expanded = [.home, .headphone, .connect, .music].contains(model.mode)
        let pad = max(model.notch.height, 32)
        // O vidro do sistema cria "fantasmas" atrasados nas transformações (visto quadro a quadro).
        // Até resolver, a ilha fica preta sólida e sincronizada.
        // Vidro sincronizado: material comum do SwiftUI (anima junto com a forma, sem fantasmas).
        // Sem vidro: ilha preta e limpa (o vidro deixava "abas" claras nas pontas ao fechar)
        let useGlass = false && glassOn
        let shapeSize = CGSize(width: s.width + 2 * r.top, height: max(s.height, 1))
        // cresce só para a direita: a esquerda continua alinhada ao notch
        let shift = model.extra(model.mode) / 2
        let base = model.baseSize(model.mode)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                LiquidContainer(spacing: 16) {
                    ZStack(alignment: .top) {
                        if model.mode.isIdleLike {
                            LiquidHUD(island: s, glass: false)
                        }
                    }
                }

                // corpo preto: SEMPRE inteiro (nunca some, nem no meio da transformação)
                NotchShape(topRadius: r.top, bottomRadius: r.bottom)
                    .fill(Color.black)
                    .frame(width: shapeSize.width, height: max(shapeSize.height, 1))
                    .offset(x: shift)
                // vidro por cima, só nas pontas (parada) ou na base (expandida);
                // some enquanto a forma se mexe (este material respeita opacidade)
                if useGlass {
                    SyncedGlass(shape: NotchShape(topRadius: r.top, bottomRadius: r.bottom))
                        .frame(width: shapeSize.width, height: max(shapeSize.height, 1))
                        .mask(GlassMask(
                            solidHeight: model.mode == .claudeThink
                                ? max(model.notch.height, 32) + 6
                                : ([.home, .headphone, .connect].contains(model.mode) ? max(1, shapeSize.height - 18) : nil))
                            .frame(width: shapeSize.width, height: max(shapeSize.height, 1)))
                        // quase invisível em vez de 0: o macOS não remove a camada de desfoque
                        // (remover custava um quadro perdido bem no início da animação)
                        .opacity(model.glassReady ? 1 : 0.001)
                }

                ZStack(alignment: .top) {
                if model.contentVisible {
                    Group {
                        switch model.mode {
                        case .home:
                            VStack(spacing: 0) { TopBar(model: model); TabContent(model: model) }
                                .frame(width: DS.Metric.panelWidth)
                        case .headphone:
                            VStack(spacing: 0) { TopBar(model: model); HeadphoneContent() }
                                .frame(width: DS.Metric.panelWidth)
                        case .connect:
                            ConnectContent(model: model).padding(.top, pad)
                                .frame(width: IslandModel.connectWidth)
                        case .compact:
                            CompactContent(model: model).frame(width: base.width)
                        case .live:
                            LiveMusicContent(model: model).frame(width: base.width)
                        case .claude:
                            ClaudeLiveContent(model: model).frame(width: base.width)
                        case .claudeThink:
                            ClaudeThinkContent(model: model).frame(width: s.width, height: s.height, alignment: .top)
                        case .music:
                            VStack(spacing: 0) { TopBar(model: model); MusicExpanded() }
                                .frame(width: DS.Metric.panelWidth)
                        case .timer:
                            TimerLiveContent(model: model).frame(width: base.width)
                        case .charging:
                            ChargingContent(model: model).frame(width: base.width)
                        case .alert:
                            AlertContent(model: model).padding(.top, pad).frame(width: s.width)
                        case .closed: EmptyView()
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -4)),
                        // o que sai encolhe para dentro do notch junto com a forma e se apaga
                        removal: AnyTransition.opacity.combined(with: .scale(scale: 0.85, anchor: .top))
                            .animation(.easeIn(duration: 0.14))))
                }
                }
                .frame(width: canvas.width, alignment: .top)
                // recorte único que acompanha a forma enquanto ela anima: inclusive o conteúdo saindo
                .mask(alignment: .top) {
                    NotchShape(topRadius: r.top, bottomRadius: r.bottom)
                        .frame(width: shapeSize.width, height: max(shapeSize.height, 1))
                        .offset(x: shift)
                }

                // segunda atividade: ícone no fim da asa direita, depois de uma linha fina
                if let k = model.secondary, model.extra(model.mode) > 0, model.contentVisible {
                    let w = IslandModel.secondaryWidth
                    HStack(spacing: 0) {
                        Capsule().fill(Color.white.opacity(0.18)).frame(width: 1, height: 16)
                        SecondaryIcon(kind: k).frame(width: w - 1)
                    }
                    .frame(width: w, height: max(model.notch.height, 32))
                    .offset(x: base.width / 2 + w / 2 - 4)
                    .id(k)
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
                }
            }
            .animation(DS.Motion.pop, value: model.secondary)
            .contentShape(Rectangle())
            .onTapGesture { IslandController.shared.tapped() }
            // soltar arquivos no notch: vão para a estante
            .onDrop(of: [.fileURL], isTargeted: Binding(
                get: { model.dropTargeted },
                set: { t in model.dropTargeted = t; if t { IslandController.shared.dropEntered() } })) { providers in
                IslandController.shared.drop(providers); return true
            }
            Spacer(minLength: 0)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .animation(DS.Motion.pick(model.growing ? DS.Motion.open : DS.Motion.close), value: model.mode)
        .animation(.easeOut(duration: 0.2), value: model.contentVisible)
    }
}

// MARK: - Controlador

/// Painel da ilha: pode receber teclado (para digitar uma tarefa) sem ativar o app.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class IslandController {
    static let shared = IslandController()
    let model = IslandModel()
    private var panel: NSPanel?
    private var screen: NSScreen?
    private var mouseTimer: Timer?
    private var hovering = false
    private var work: [DispatchWorkItem] = []
    private let canvas = CGSize(width: 640, height: 430)

    private var playObs: Any?

    /// O aviso de volume/brilho só sai do notch quando a ilha não está aberta.
    var allowsHUD: Bool { model.mode.isIdleLike }

    /// Estado "parado": compacto com música tocando, senão invisível.
    /// Atividades acontecendo agora, por prioridade (a 1ª fica nas asas, a 2ª vira bolinha).
    var liveKinds: [LiveKind] {
        var k: [LiveKind] = []
        if ClaudeActivity.shared.active { k.append(.claude) }
        if TimerModel.shared.active && Features.timer { k.append(.timer) }
        if NowPlaying.shared.isPlaying { k.append(.music) }
        return k
    }

    var idleMode: IslandMode {
        let c = ClaudeActivity.shared
        if c.phase == .thinking && c.domeVisible { return .claudeThink }
        switch liveKinds.first {
        case .claude: return .claude
        case .timer: return .timer
        case .music: return .live
        case nil: return .closed
        }
    }

    private func updateSecondary() {
        let k = liveKinds
        let s: LiveKind? = k.count > 1 ? k[1] : nil
        if model.secondary != s { model.secondary = s }
    }

    func bubbleTapped(_ k: LiveKind) {
        switch k {
        case .timer: openTab(.timer)
        case .music:
            if UserDefaults.standard.string(forKey: "musicClick") == "open" { NowPlaying.shared.openPlayingApp() } else { openMusic() }
        case .claude: break
        }
    }
    private var claudeObs: Any?
    private var domeObs: Any?

    func start() {
        layout()
        playObs = NowPlaying.shared.$isPlaying.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.idleChanged() }
        }
        claudeObs = ClaudeActivity.shared.$phase.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.idleChanged() }
        }
        domeObs = ClaudeActivity.shared.$domeVisible.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.idleChanged() }
        }
        // Gatilhos internos de teste (usados para gravar e conferir as animações)
        DistributedNotificationCenter.default().addObserver(forName: .init("local.ohmynotch.debug"), object: nil, queue: .main) { [weak self] n in
            self?.debug(n.object as? String ?? "")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layout() }
        // Robustez (reclamação nº 2 dos concorrentes: "o notch some depois do repouso"):
        // ao acordar, trocar de mesa virtual ou de tela, reposiciona e traz a ilha de volta.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.recover() }
        }
        // Avisos de movimento do mouse (sem ficar checando o tempo todo)
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.checkMouse() }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in self?.noteMouseDown() }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseExited]) { [weak self] e in
            self?.checkMouse(); return e
        }
        // Rede de segurança lenta (ex.: a ilha mudou de tamanho sem o mouse se mexer)
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkMouse() }
    }

    /// Em qual tela a ilha fica. Padrão: segue a tela onde está o mouse (monitor externo incluso);
    /// telas sem notch ganham uma pílula no topo central.
    private func preferredScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let notchScreen = screens.first(where: { $0.safeAreaInsets.top > 0 })
        if (UserDefaults.standard.string(forKey: "islandScreen") ?? "follow") == "notch", let n = notchScreen { return n }
        let mouse = NSEvent.mouseLocation
        return screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? notchScreen ?? NSScreen.main ?? screens.first
    }

    private func layout(for target: NSScreen? = nil) {
        guard let s = target ?? preferredScreen() else { return }
        screen = s
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            model.notch = CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
        } else {
            model.notch = CGSize(width: 180, height: 0)
        }
        if panel == nil {
            let p = IslandPanel(contentRect: NSRect(origin: .zero, size: canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isMovable = false
            p.becomesKeyOnlyIfNeeded = true
            p.ignoresMouseEvents = true
            p.acceptsMouseMovedEvents = true
            p.contentView = NSHostingView(rootView: IslandRoot(model: model, canvas: canvas))
            panel = p
        }
        panel?.setFrameOrigin(NSPoint(x: s.frame.midX - canvas.width / 2, y: s.frame.maxY - canvas.height))
        panel?.orderFrontRegardless()
    }

    /// Volta tudo ao estado certo depois de repouso/troca de tela.
    func recover() {
        // espera a tela assentar (as medidas do notch podem chegar um instante depois)
        for delay in [0.0, 0.8, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.layout()
                self.panel?.orderFrontRegardless()
                if !self.hovering { self.setMode(self.idleMode) }
            }
        }
        MediaKeys.shared.stop(); MediaKeys.shared.start()
        NotificationMirror.shared.start()
        HeadphoneBattery.shared.refresh(force: true)
    }

    /// Retângulo atual da ilha em coordenadas de tela (com folga).
    private func hotZone() -> NSRect {
        guard let s = screen else { return .zero }
        let size = model.size(model.mode)
        let r = model.radii(model.mode)
        let w = size.width + 2 * r.top
        let extra: CGFloat = model.mode == .closed ? 8 : 4
        let h = max(size.height, 6) + extra
        let shift = model.extra(model.mode) / 2
        return NSRect(x: s.frame.midX + shift - w / 2 - extra, y: s.frame.maxY - h, width: w + 2 * extra, height: h + 10)
    }

    private func checkMouse() {
        // mouse foi para outra tela: a ilha vai junto (só quando não está aberta)
        if NSScreen.screens.count > 1, !hovering,
           model.mode.isIdleLike,
           let target = preferredScreen(), target != screen {
            layout(for: target)
        }
        var inside = hotZone().contains(NSEvent.mouseLocation)
        // segurando: digitando uma tarefa ou arrastando um arquivo da estante
        if typing || shelfDragging { inside = true }
        if shelfDragging && NSEvent.pressedMouseButtons & 1 == 0 { shelfDragging = false }
        // arrastando um arquivo perto do notch: a ilha aceita a soltura
        if !inside && NSEvent.pressedMouseButtons & 1 != 0 && dragHasFiles() {
            inside = hotZone().insetBy(dx: -30, dy: -24).contains(NSEvent.mouseLocation)
        }
        panel?.ignoresMouseEvents = !inside
        guard inside != hovering else { return }
        hovering = inside
        inside ? hoverBegan() : hoverEnded()
    }

    private func cancelWork() { work.forEach { $0.cancel() }; work.removeAll() }
    private func after(_ s: Double, _ f: @escaping () -> Void) {
        let w = DispatchWorkItem(block: f); work.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    private func hoverBegan() {
        switch model.mode {
        case .closed, .compact, .live, .claude, .claudeThink, .timer, .charging:
            cancelWork()
            CalendarFeed.shared.start()
            HeadphoneBattery.shared.refresh()
            if !HomeTab.visible.contains(model.tab) { model.tab = .home }
            after(0.08) { [weak self] in if self?.hovering == true { self?.setMode(.home) } }
        case .connect, .alert:
            cancelWork()     // pausa enquanto o mouse está em cima
        default: break
        }
    }

    private func hoverEnded() {
        cancelWork()
        after(0.35) { [weak self] in self?.close() }
    }

    private func idleChanged() {
        updateSecondary()
        if model.mode.isIdleLike && model.mode != .compact && model.mode != .charging { setMode(idleMode) }
    }

    func tapped() {
        switch model.mode {
        case .compact, .connect: cancelWork(); setMode(.headphone)
        case .alert:
            let a = model.alert?.action
            cancelWork(); model.alert = nil
            setMode(hovering ? .home : idleMode)
            a?()
        default: break
        }
    }

    // MARK: Abas, avisos, estante

    private var typing = false
    private var shelfDragging = false
    private var dragDownCount = NSPasteboard(name: .drag).changeCount
    func beginTyping() { typing = true; panel?.makeKey() }
    func endTyping() { typing = false; panel?.resignKey(); checkMouse() }
    func beginShelfDrag() { shelfDragging = true }

    func noteMouseDown() { dragDownCount = NSPasteboard(name: .drag).changeCount }
    private func dragHasFiles() -> Bool {
        let pb = NSPasteboard(name: .drag)
        return Features.shelf && pb.changeCount != dragDownCount && (pb.types?.contains(.fileURL) ?? false)
    }

    func openTab(_ t: HomeTab) {
        cancelWork()
        model.tab = t
        if model.mode != .home { setMode(.home) }
        // abriu sem o mouse em cima: fecha sozinha depois de um tempo
        after(6) { [weak self] in if self?.hovering == false { self?.close() } }
    }

    func dropEntered() {
        guard Features.shelf else { return }
        cancelWork()
        model.tab = .shelf
        if model.mode != .home { setMode(.home) }
    }

    func drop(_ providers: [NSItemProvider]) {
        guard Features.shelf else { return }
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { Shelf.shared.add([url]) }
            }
        }
        model.tab = .shelf
    }

    func timerChanged() { idleChanged() }

    /// Aviso rápido no notch (some sozinho; pausa com o mouse em cima; clique = ação).
    func showAlert(_ a: IslandAlert, duration: Double = 4) {
        // com o painel aberto pelo mouse, não atrapalha o que você está fazendo
        if hovering && [.home, .headphone, .music].contains(model.mode) { return }
        cancelWork()
        if model.mode == .alert {
            model.contentVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.model.alert = a; self?.model.contentVisible = true
            }
        } else {
            model.alert = a
            setMode(.alert)
        }
        after(duration) { [weak self] in
            guard let self, !self.hovering else { return }
            self.model.alert = nil
            self.setMode(self.idleMode)
        }
    }

    /// Carregador conectado: asas verdes por alguns segundos.
    func showCharging() {
        guard model.mode.isIdleLike || model.mode == .closed else { return }
        cancelWork()
        NSSound(named: "Tink")?.play()
        setMode(.charging)
        after(3.2) { [weak self] in
            guard let self, self.model.mode == .charging else { return }
            self.setMode(self.idleMode)
        }
    }

    private func debug(_ cmd: String) {
        switch cmd {
        case "home": cancelWork(); setMode(.home)
        case "recover": recover()
        case "music": openMusic()
        case "headphone": cancelWork(); setMode(.headphone)
        case "close": cancelWork(); setMode(idleMode)
        case "connect": AudioMonitor.shared.showConnectAnimation()
        case "hud": HUDModel.shared.show(.volume, AudioMonitor.shared.volume)
        case "limit": HUDModel.shared.show(.volume, AudioMonitor.shared.limit, limited: true)
        case "claudeOff": ClaudeActivity.shared.paused = true
        case "claudeOn": ClaudeActivity.shared.paused = false
        case "think": ClaudeActivity.shared.debugSet(.thinking, "Pensando…")
        case "work": ClaudeActivity.shared.debugSet(.working, "Editando Island.swift")
        case "done": ClaudeActivity.shared.debugSet(.done, "Pronto")
        case "wait": ClaudeActivity.shared.debugSet(.waiting, "Esperando sua resposta")
        case "charging": showCharging()
        case "lowbat": showAlert(IslandAlert(symbol: "battery.25percent", color: .red, title: L("Bateria fraca"),
                                             subtitle: LF("%d%% restantes · conecte o carregador", 20)), duration: 6)
        case "timer": TimerModel.shared.set(minutes: 1); TimerModel.shared.startTimer()
        case "timerStop": TimerModel.shared.reset()
        case "timerDone": showAlert(IslandAlert(symbol: "timer", color: .orange, title: L("Timer acabou"), subtitle: "5:00"), duration: 8)
        case "notif": showAlert(IslandAlert(symbol: "bell.fill", color: .red, title: "Maria", subtitle: "Bora jogar hoje à noite?",
                                            image: NotificationMirror.icon(forAppNamed: "Messages"), appName: "Mensagens"), duration: 5)
        case "axdump": NotificationMirror.shared.dump()
        case "shelfClear": Shelf.shared.clear()
        case "tasks": openTab(.tasks)
        case "tabtimer": openTab(.timer)
        case "shelf": openTab(.shelf)
        case "stats": openTab(.stats)
        case "tabhome": openTab(.home)
        default: break
        }
    }

    func openMusic() {
        cancelWork()
        NowPlaying.shared.setDetailed(true)
        setMode(.music)
    }

    func toggleHeadphone() {
        cancelWork()
        setMode(model.mode == .headphone ? .home : .headphone)
    }

    func close() {
        guard !hovering else { return }
        setMode(idleMode)
    }

    func setMode(_ m: IslandMode) {
        guard m != model.mode else { return }
        if m != .home && typing { endTyping() }
        if (model.mode == .home && m == .headphone) || (model.mode == .headphone && m == .home) {
            model.contentVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.model.mode = m
                self?.model.contentVisible = true
            }
            return
        }
        if m != .music { NowPlaying.shared.setDetailed(false) }
        let old = model.size(model.mode), new = model.size(m)
        let grow = new.width * new.height >= old.width * old.height
        // Forma e conteúdo mudam juntos: o conteúdo antigo sai rápido enquanto a forma
        // já começa a crescer/encolher (nada de caixa vazia no meio).
        model.growing = grow
        model.contentVisible = false
        model.glassReady = false
        model.mode = m
        let settle = grow ? 0.46 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, self.model.mode == m else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.model.glassReady = true }
        }
        guard m != .closed else { return }
        // o novo conteúdo entra quando a forma está ~60% do caminho
        // ao encolher, o conteúdo pequeno só entra quando a forma já quase assentou
        DispatchQueue.main.asyncAfter(deadline: .now() + (grow ? 0.16 : 0.26)) { [weak self] in
            if self?.model.mode == m { self?.model.contentVisible = true }
        }
    }

    /// Fone conectou: expande com os fones girando, vira "asas" e some.
    func showConnect(name: String, sound: Bool) {
        cancelWork()
        model.connectName = name
        HeadphoneBattery.shared.refresh(force: true)
        if sound { NSSound(named: "Glass")?.play() }
        if !(model.mode.isIdleLike && model.mode != .compact) { model.contentVisible = false; model.mode = .closed }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.setMode(.connect) }
        after(4.5) { [weak self] in
            guard let self, !self.hovering else { return }
            self.setMode(.compact)
            self.after(4) { [weak self] in self?.close() }
        }
    }
}

// MARK: - Snapshot para conferência: OhMyNotch --snapshot arquivo.png [open|connect|compact]

@MainActor func renderIslandSnapshot(to path: String, mode: String) {
    let model = IslandModel()
    model.notch = CGSize(width: 208, height: 37.5)
    model.connectName = "QCY MeloBuds Pro"
    model.mode = mode == "musicx" ? .music : mode == "connect" ? .connect : (mode == "compact" ? .compact : (mode == "headphone" ? .headphone : (mode == "live" ? .live : (mode == "claude" ? .claude : (mode == "think" ? .claudeThink : .home)))))
    let tabModes: [String: HomeTab] = ["tasks": .tasks, "timertab": .timer, "shelf": .shelf, "stats": .stats]
    if let t = tabModes[mode] { model.mode = .home; model.tab = t; UserDefaults.standard.register(defaults: ["featureStats": true]) }
    if mode == "multi" { model.mode = .claude; model.secondary = .music; ClaudeActivity.shared.phase = .working; ClaudeActivity.shared.text = "Editando Island.swift"; NowPlaying.shared.title = "Yellow"; NowPlaying.shared.isPlaying = true }
    if mode == "multi2" { model.mode = .timer; model.secondary = .music; TimerModel.shared.set(minutes: 5); TimerModel.shared.startTimer(); TimerModel.shared.pause(); NowPlaying.shared.title = "Yellow"; NowPlaying.shared.isPlaying = true }
    if mode == "multi3" { model.mode = .live; model.secondary = .timer; NowPlaying.shared.title = "Yellow"; NowPlaying.shared.isPlaying = true; TimerModel.shared.set(minutes: 5); TimerModel.shared.startTimer(); TimerModel.shared.pause() }
    if mode == "timer" { model.mode = .timer; TimerModel.shared.set(minutes: 5); TimerModel.shared.startTimer(); TimerModel.shared.pause() }
    if mode == "charging" { model.mode = .charging; PowerMonitor.shared.level = 82 }
    if mode == "alert" { model.mode = .alert; model.alert = IslandAlert(symbol: "timer", color: .orange, title: "Timer acabou", subtitle: "5:00") }
    if mode == "notif" { model.mode = .alert; model.alert = IslandAlert(symbol: "bell.fill", color: .red, title: "Maria", subtitle: "Bora jogar hoje à noite?", image: NotificationMirror.icon(forAppNamed: "Messages"), appName: "Mensagens") }
    if mode == "stats" { PowerMonitor.shared.hasBattery = true; PowerMonitor.shared.level = 76; SystemStats.shared.cpu = 0.23; SystemStats.shared.memUsed = 5.4 * 1_073_741_824 }
    if mode == "claude" { ClaudeActivity.shared.phase = .working; ClaudeActivity.shared.text = "Editando Island.swift" }
    if mode == "think" { ClaudeActivity.shared.phase = .thinking; ClaudeActivity.shared.text = "Pensando…" }
    HeadphoneBattery.shared.info = BatteryInfo(main: 90)
    if mode == "musicx" { NowPlaying.shared.upNext = ["Fix You — Coldplay", "The Scientist — Coldplay", "Clocks — Coldplay"]; NowPlaying.shared.duration = 266; NowPlaying.shared.position = 92 }
    if mode == "music" || mode == "live" || mode == "musicx" { NowPlaying.shared.title = "Lose Yourself"; NowPlaying.shared.artist = "Eminem"; NowPlaying.shared.isPlaying = true }
    model.contentVisible = true
    let view = IslandRoot(model: model, canvas: CGSize(width: 640, height: mode == "musicx" ? 330 : 200))
        .background(LinearGradient(colors: [Color(red: 0.07, green: 0.1, blue: 0.3), Color(red: 0.25, green: 0.35, blue: 0.75)],
                                   startPoint: .top, endPoint: .bottom))
    let r = ImageRenderer(content: view); r.scale = 2
    if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t) {
        try? b.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
