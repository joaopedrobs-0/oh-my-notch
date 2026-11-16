// Widget na tela de bloqueio (acima da foto de perfil), como no iPhone.
//
// A Apple não oferece um jeito oficial de desenhar na tela de bloqueio. Aqui usamos
// a mesma técnica da biblioteca SkyLightWindow (github.com/Lakr233/SkyLightWindow, MIT):
// criar um "espaço" do SkyLight (framework interno do macOS) num nível acima da
// tela de bloqueio e colocar a nossa janela nele. Pode parar de funcionar numa
// atualização do macOS; se as funções não existirem, o widget simplesmente não aparece.

import SwiftUI
import AppKit

// MARK: - SkyLight

final class SkyLightSpace {
    static let shared = SkyLightSpace()

    private typealias FMainConn = @convention(c) () -> Int32
    private typealias FSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias FSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias FShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias FAddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private var connection: Int32 = 0
    private var space: Int32 = 0
    private var addWindows: FAddWindows?
    private(set) var available = false

    private init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let pConn = dlsym(h, "SLSMainConnectionID"),
              let pCreate = dlsym(h, "SLSSpaceCreate"),
              let pLevel = dlsym(h, "SLSSpaceSetAbsoluteLevel"),
              let pShow = dlsym(h, "SLSShowSpaces"),
              let pAdd = dlsym(h, "SLSSpaceAddWindowsAndRemoveFromSpaces") else { return }
        let mainConn = unsafeBitCast(pConn, to: FMainConn.self)
        let create = unsafeBitCast(pCreate, to: FSpaceCreate.self)
        let setLevel = unsafeBitCast(pLevel, to: FSetLevel.self)
        let show = unsafeBitCast(pShow, to: FShowSpaces.self)
        addWindows = unsafeBitCast(pAdd, to: FAddWindows.self)
        connection = mainConn()
        space = create(connection, 1, 0)
        _ = setLevel(connection, space, 400)   // nível da Central de Notificações na tela de bloqueio
        _ = show(connection, [space] as CFArray)
        available = true
    }

    func adopt(_ window: NSWindow) {
        guard available, let addWindows else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }
}

// MARK: - Views

// Tela de bloqueio usa o vidro transparente (.clear) do sistema de design;
// textos ganham sombra leve para ficarem legíveis sobre qualquer papel de parede.

struct LockMusicCard: View {
    @ObservedObject var np = NowPlaying.shared
    var body: some View {
        HStack(spacing: 12) {
            Artwork(image: np.artwork, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(np.title).font(DS.Font.headline).foregroundStyle(DS.Palette.primary).lineLimit(1)
                Text(np.artist).font(DS.Font.body).foregroundStyle(DS.Palette.primary.opacity(0.8)).lineLimit(1)
            }
            .legibleOnGlass()
            Spacer(minLength: 6)
            MusicControls().legibleOnGlass()
        }
        .padding(12)
        .frame(width: 330, height: 72)
        .dsGlass(RoundedRectangle(cornerRadius: DS.Metric.card, style: .continuous), .clear)
    }
}

struct LockHeadphonePill: View {
    @ObservedObject var m = AudioMonitor.shared
    @ObservedObject var battery = HeadphoneBattery.shared
    var body: some View {
        HStack(spacing: 8) {
            DeviceGlyph(name: m.deviceName, width: 24)
            Text(m.deviceName).font(DS.Font.headline).foregroundStyle(DS.Palette.primary).lineLimit(1).legibleOnGlass()
            if let l = battery.level {
                BatteryRing(level: l, size: 18, line: 2.5)
                Text("\(l)%").font(DS.Font.value).foregroundStyle(DS.Palette.primary.opacity(0.85)).legibleOnGlass()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .dsGlass(Capsule(), .clear)
    }
}

/// Bolha de vidro com o fone e o anel de bateria (estilo MagSafe).
struct LockHeadphoneBubble: View {
    @ObservedObject var m = AudioMonitor.shared
    @ObservedObject var battery = HeadphoneBattery.shared
    var size: CGFloat = 72
    var contentVisible = true

    var body: some View {
        ZStack {
            BatteryRing(level: battery.level, size: size - 10, line: 3, pulse: true) {
                DeviceGlyph(name: m.deviceName, width: size * 0.48)
                    .shadow(color: .white.opacity(0.3), radius: 4)
            }
            if let l = battery.level {
                Text("\(l)%").font(DS.Font.caption).monospacedDigit()
                    .foregroundStyle(DS.Palette.primary).legibleOnGlass()
                    .offset(y: size * 0.3)
            }
        }
        .opacity(contentVisible ? 1 : 0)
        .scaleEffect(contentVisible ? 1 : 0.6)
        .animation(DS.Motion.pop, value: contentVisible)
        .frame(width: size, height: size)
        .dsGlass(Circle(), .clear)
    }
}

final class LockModel: ObservableObject {
    @Published var visible = false
    @Published var split = false      // bolha do fone já se soltou do card
}

struct LockRoot: View {
    @ObservedObject var model: LockModel
    @ObservedObject var np = NowPlaying.shared
    @ObservedObject var m = AudioMonitor.shared

    static let bubble: CGFloat = 72
    static let gap: CGFloat = 26           // maior que o espaçamento de fusão: separa de vez
    static let mergeSpacing: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if model.visible {
                LiquidContainer(spacing: Self.mergeSpacing) {
                    HStack(spacing: Self.gap) {
                        if np.hasTrack { LockMusicCard().zIndex(1) }
                        if m.isHeadphone {
                            if np.hasTrack {
                                LockHeadphoneBubble(size: Self.bubble, contentVisible: model.split)
                                    // antes de se soltar: escondida dentro da borda do card
                                    .offset(x: model.split ? 0 : -(Self.bubble * 0.75 + Self.gap))
                                    .scaleEffect(model.split ? 1 : 0.55)
                            } else {
                                LockHeadphonePill()
                            }
                        }
                    }
                }
                .transition(.scale(scale: 0.8, anchor: .center).combined(with: .opacity))
            }
        }
        .frame(width: 460, height: 130)
        .animation(DS.Motion.pick(DS.Motion.open), value: model.visible)
        .animation(DS.Motion.pick(.spring(duration: 0.9, bounce: 0.42)), value: model.split)
        .animation(DS.Motion.swap, value: np.hasTrack)
    }
}

// MARK: - Controlador

final class LockScreenController {
    static let shared = LockScreenController()
    private var window: NSWindow?
    private let model = LockModel()
    private let size = CGSize(width: 460, height: 130)

    /// Altura do widget (fração da tela, a partir de baixo): logo acima da foto de perfil.
    static let heightFraction: CGFloat = 0.30

    func start() {
        // registra sempre: o widget pode ser ligado depois, nos Recursos (locked() confere a preferência)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.unlocked()
        }
    }

    private func makeWindow() -> NSWindow? {
        guard SkyLightSpace.shared.available else { return nil }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isMovable = false
        w.canBecomeVisibleWithoutLogin = true
        w.level = NSWindow.Level(rawValue: Int(Int32.max - 2))
        w.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        w.contentView = NSHostingView(rootView: LockRoot(model: model))
        return w
    }

    private func locked() {
        guard Prefs.lockScreenWidget else { return }
        if window == nil { window = makeWindow() }
        guard let w = window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.frame
        w.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + f.height * Self.heightFraction))
        w.orderFrontRegardless()
        SkyLightSpace.shared.adopt(w)
        HeadphoneBattery.shared.refresh()
        model.visible = false
        model.split = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.model.visible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.4 : 1.0)) { self.model.split = true }
    }

    private func unlocked() {
        model.split = false
        model.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if self?.model.visible == false { self?.window?.orderOut(nil) }
        }
    }
}

@MainActor func renderLockSnapshot(to path: String) {
    NowPlaying.shared.title = "Lose Yourself"; NowPlaying.shared.artist = "Eminem"; NowPlaying.shared.isPlaying = true
    HeadphoneBattery.shared.info = BatteryInfo(main: 90)
    func frame(_ split: Bool) -> some View {
        let m = LockModel(); m.visible = true; m.split = split
        return LockRoot(model: m)
    }
    let view = VStack(spacing: 0) {
        frame(false)
        frame(true)
    }
    .padding(20)
    .background(LinearGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.5), Color(red: 0.6, green: 0.3, blue: 0.4)],
                               startPoint: .top, endPoint: .bottom))
    let r = ImageRenderer(content: view); r.scale = 2
    if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t) {
        try? b.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
