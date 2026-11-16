// Aviso de volume e brilho que sai do notch como uma gota de líquido
// (efeito "metaball": desfoque + limiar de transparência funde as formas pretas).
//
// Motion design aplicado:
// - origem consistente: nasce do notch e volta para ele
// - squash & stretch: estica descendo, achata ao chegar (volume preservado)
// - follow-through: conteúdo chega ~120 ms depois da forma
// - saída ≈ 70% da entrada, acelerando e sem quique

import SwiftUI
import AppKit

enum HUDKind { case volume, brightness }

final class HUDModel: ObservableObject {
    static let shared = HUDModel()

    @Published var kind: HUDKind = .volume
    @Published var value: Float = 0
    @Published var limited = false       // volume bateu no limite seguro
    @Published var out = false           // gota separada do notch
    @Published var contentVisible = false
    @Published var animating = false
    let sim = GooSim()
    private var stopWork: DispatchWorkItem?

    private var hideWork: DispatchWorkItem?
    private var contentWork: DispatchWorkItem?


    func show(_ k: HUDKind, _ v: Float, limited: Bool = false) {
        guard IslandController.shared.allowsHUD, Features.hud || limited else { return }
        if kind != k || self.limited != limited {
            withAnimation(DS.Motion.swap) { kind = k; self.limited = limited }
        }
        value = v
        stopWork?.cancel()
        animating = true
        if !out {
            out = true
            contentWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                withAnimation(DS.Motion.fadeIn) { self?.contentVisible = true }
            }
            contentWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + DS.Motion.contentDelay, execute: w)
        }
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (limited ? 2.6 : 2.0), execute: w)
    }

    func hide() {
        let w = DispatchWorkItem { [weak self] in if self?.out == false { self?.animating = false } }
        stopWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: w)
        contentWork?.cancel()
        withAnimation(DS.Motion.fadeOut) { contentVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.out = false }
    }
}

// MARK: - Brilho da tela (DisplayServices, framework interno; se faltar, só não mostra)

final class BrightnessMonitor {
    static let shared = BrightnessMonitor()
    private typealias FGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias FSet = @convention(c) (UInt32, Float) -> Int32
    private var get: FGet?
    private var setFn: FSet?

    var canSet: Bool { setFn != nil && read() != nil }

    /// Ajuste pelas teclas (quando o app substitui o aviso do macOS).
    func step(_ delta: Float) {
        guard let setFn, let cur = read() else { return }
        let v = max(0, min(1, cur + delta))
        _ = setFn(CGMainDisplayID(), v)
        last = v
        HUDModel.shared.show(.brightness, v)
    }
    private var last: Float = -1
    private var timer: Timer?
    private var manualUntil = Date.distantPast

    func start() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let p = dlsym(h, "DisplayServicesGetBrightness") else { return }
        get = unsafeBitCast(p, to: FGet.self)
        if let ps = dlsym(h, "DisplayServicesSetBrightness") { setFn = unsafeBitCast(ps, to: FSet.self) }
        last = read() ?? -1
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.25   // deixa o macOS agrupar o despertar (economiza bateria)
    }

    private func read() -> Float? {
        guard let get else { return nil }
        var v: Float = 0
        return get(CGMainDisplayID(), &v) == 0 ? v : nil
    }

    private func poll() {
        guard let v = read() else { return }
        guard last >= 0 else { last = v; return }
        let delta = abs(v - last)
        // Brilho automático (sensor de luz) muda em passos minúsculos e graduais;
        // teclas/controle mudam em saltos de ~6%. Só o manual mostra o aviso.
        if delta >= 0.05 {
            HUDModel.shared.show(.brightness, v)
            manualUntil = Date().addingTimeInterval(1.2)
        } else if delta > 0.003, Date() < manualUntil, HUDModel.shared.kind == .brightness {
            HUDModel.shared.show(.brightness, v)   // continua atualizando enquanto você ajusta
        }
        last = v
    }
}

// MARK: - Física (mola + membrana elástica + gelatina)

/// Simulação simples: a cápsula é puxada por uma mola; a base da ilha estica junto
/// (membrana) até a distância de ruptura; aí a membrana volta com tranco e a cápsula
/// fica balançando como gelatina. Estica conforme a velocidade (squash & stretch real).
final class GooSim {
    var y: CGFloat = -30          // centro da cápsula em relação à base da ilha (negativo = dentro)
    var vy: CGFloat = 0
    var my: CGFloat = 0           // quanto a membrana está esticada para baixo
    var vmy: CGFloat = 0
    var attached = true
    var wobbleT: Double = 10
    var wobbleA: CGFloat = 0
    private var last: Date?

    static let snapDistance: CGFloat = 15

    struct State {
        var y: CGFloat, my: CGFloat, sx: CGFloat, sy: CGFloat, emerge: CGFloat, attached: Bool
    }

    func step(_ date: Date, out: Bool, hiddenY: CGFloat, restY: CGFloat, pillH: CGFloat) -> State {
        let raw = last.map { date.timeIntervalSince($0) } ?? 1 / 60
        last = date
        let dt = CGFloat(min(max(raw, 0), 1 / 30)) / 4
        let target = out ? restY : hiddenY
        for _ in 0..<4 {
            // mola da cápsula: saída com quique, volta firme
            // mola mais macia: ida ~0,7 s com quique elástico; volta ~0,45 s firme
            let k: CGFloat = out ? 85 : 130, c: CGFloat = out ? 10.5 : 21
            vy += (-k * (y - target) - c * vy) * dt
            y += vy * dt

            let gapTop = (y - pillH / 2)          // distância do topo da cápsula até a base da ilha
            if attached {
                if out && gapTop > Self.snapDistance {          // arrebenta
                    attached = false
                    wobbleA = min(0.22, 0.1 + abs(vy) / 2500)
                    wobbleT = 0
                    vmy -= 120                                   // tranco da membrana voltando
                }
            } else if !out && gapTop < 2 {
                attached = true                                  // voltou e fundiu
            }
            let mTarget: CGFloat = attached ? max(0, gapTop + 4) : 0
            let km: CGFloat = attached ? 260 : 150, cm: CGFloat = attached ? 24 : 8
            vmy += (-km * (my - mTarget) - cm * vmy) * dt
            my += vmy * dt
            wobbleT += Double(dt)
        }
        let speed = abs(vy)
        var sy = 1 + min(0.3, speed / 600)        // estica na direção do movimento
        var sx = 1 / sy                           // volume preservado
        if wobbleA > 0 {                          // gelatina depois de soltar
            let f = wobbleA * CGFloat(exp(-4.5 * wobbleT) * sin(2 * .pi * 4 * wobbleT))
            sx *= 1 + f; sy *= 1 - f
        }
        let emerge = min(1, max(0, (y - hiddenY) / (restY - hiddenY)))
        return State(y: y, my: max(-6, my), sx: sx, sy: sy, emerge: emerge, attached: attached)
    }
}

// MARK: - Conteúdo

struct HUDContent: View {
    @ObservedObject var hud = HUDModel.shared
    @ObservedObject var m = AudioMonitor.shared

    var icon: String {
        switch hud.kind {
        case .brightness: return hud.value < 0.35 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if hud.value < 0.01 { return "speaker.slash.fill" }
            return hud.value < 0.34 ? "speaker.wave.1.fill" : (hud.value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
        }
    }
    var tint: Color { hud.limited ? DS.Palette.warning : DS.Palette.primary }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(DS.Font.icon(13))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)
            SafeVolumeBar(volume: hud.value, limit: m.limit,
                          limiting: hud.kind == .volume && m.isLimiting, tint: tint, height: 5)
            Group {
                if hud.limited {
                    Label("Limite", systemImage: "shield.lefthalf.filled")
                        .labelStyle(.titleAndIcon)
                        .symbolEffect(.bounce, value: hud.limited)
                        .foregroundStyle(DS.Palette.warning)
                } else {
                    Text(percent(hud.value)).foregroundStyle(DS.Palette.secondary)
                }
            }
            .font(DS.Font.value)
            .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .legibleOnGlass()
    }
}

// MARK: - Peças (vidro: fundem e se separam no mesmo GlassEffectContainer da ilha)

extension View {
    func islandGlass<S: InsettableShape>(_ shape: S, glass: Bool) -> some View {
        background(Group {
            if glass { SyncedGlass(shape: shape) } else { shape.fill(Color.black) }
        })
    }
}

struct LiquidHUD: View {
    @ObservedObject var hud = HUDModel.shared
    let island: CGSize            // tamanho atual da ilha (fechada / música / asas)
    let glass: Bool
    static let pill = CGSize(width: 214, height: 34)
    static let gap: CGFloat = 16

    var body: some View {
        TimelineView(.animation(paused: !hud.animating)) { ctx in
            let pillH = Self.pill.height
            let hiddenY = -(pillH / 2 + 6)
            let restY = Self.gap + pillH / 2
            let st = hud.sim.step(ctx.date, out: hud.out, hiddenY: hiddenY, restY: restY, pillH: pillH)
            pieces(st)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder func pieces(_ st: GooSim.State) -> some View {
        let pw = Self.pill.width, ph = Self.pill.height
        // nasce da largura da ilha inteira e vira cápsula ao se soltar
        // nasce com largura parecida com a da cápsula (não como uma placa da largura da ilha)
        let startW = min(max(island.width - 24, 80), pw * 1.15)
        let w = startW + (pw - startW) * st.emerge
        let h = ph * (0.62 + 0.38 * st.emerge)
        let contentAlpha = min(1, max(0, (st.y - (Self.gap + ph / 2 - 16)) / 14))
        ZStack(alignment: .top) {
            // membrana: base da ilha esticando atrás da cápsula (só existe quando esticada)
            if st.my > 0.5 {
                Capsule().fill(Color.clear)
                    .frame(width: max(30, w * 0.62 * (1 - min(0.5, st.my / 50))), height: max(1, 18 + st.my))
                    .islandGlass(Capsule(), glass: glass)
                    .offset(y: island.height - 18)
            }
            // cápsula (só existe quando saiu de dentro da ilha)
            if st.y > -h * 0.6 {
            HUDContent()
                .opacity(contentAlpha)
                .frame(width: pw, height: ph)
                .scaleEffect(x: w / pw * st.sx, y: h / ph * st.sy)
                .frame(width: w * st.sx, height: h * st.sy)
                // corpo preto aparece quando a gota já se formou; o pescoço fica só "água"
                .background(LensBody(shape: Capsule(), solidHeight: LiquidHUD.pill.height * 0.3).opacity(glass ? Double(st.emerge) : 1))
                .islandGlass(Capsule(), glass: glass)
                .offset(y: island.height + st.y - h * st.sy / 2)
            }
        }
    }
}

// Quadros para conferência: OhMyNotch --hud-snapshot arquivo.png
@MainActor func renderHUDSnapshot(to path: String) {
    let island = CGSize(width: 288, height: 37.5)
    HUDModel.shared.value = 0.6; HUDModel.shared.limited = false
    func frame(_ y: CGFloat, _ my: CGFloat, _ emerge: CGFloat, _ sx: CGFloat, _ sy: CGFloat) -> some View {
        let st = GooSim.State(y: y, my: my, sx: sx, sy: sy, emerge: emerge, attached: my > 0)
        return LiquidContainer(spacing: 16) {
            ZStack(alignment: .top) {
                LiquidHUD(island: island, glass: true).pieces(st)
                Color.clear.frame(width: island.width + 16, height: island.height)
                    .islandGlass(NotchShape(topRadius: 8, bottomRadius: 14), glass: true)
            }
        }
        .frame(width: 330, height: 110, alignment: .top)
        .background(LinearGradient(colors: [Color(red: 0.07, green: 0.1, blue: 0.3), Color(red: 0.25, green: 0.35, blue: 0.75)],
                                   startPoint: .top, endPoint: .bottom))
    }
    let view = HStack(spacing: 6) {
        frame(-8, 2, 0.35, 0.85, 1.18)
        frame(14, 14, 0.7, 0.8, 1.25)
        frame(28, 10, 0.92, 0.85, 1.2)
        frame(33, 0, 1, 1.12, 0.88)
        frame(33, 0, 1, 1, 1)
    }.padding(6)
    let r = ImageRenderer(content: view); r.scale = 2
    if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t) {
        try? b.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

