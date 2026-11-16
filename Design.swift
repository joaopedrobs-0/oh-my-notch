// Sistema de design do Oh My Notch!: um lugar só para movimento, tipografia,
// cores, raios e vidro. Toda view usa estes valores; nada de números soltos.

import SwiftUI
import AppKit

enum DS {

    // MARK: Movimento
    // Personalidade: premium com toque divertido. Uma família de molas.
    // Entrar = mola com quique leve; sair = mola sem quique, ~70% da duração.
    enum Motion {
        // Referência (Siri iOS 27, quadro a quadro): incha rápido (~130 ms) com quique;
        // ao fechar passa um pouco da largura final e volta (overshoot).
        static let open   = Animation.spring(duration: 0.42, bounce: 0.3)    // ilha crescendo
        static let close  = Animation.spring(duration: 0.38, bounce: 0.16)   // encolhe com overshoot leve
        static let pop    = Animation.spring(duration: 0.5, bounce: 0.34)    // elementos pequenos entrando
        static let swap   = Animation.snappy(duration: 0.18)                 // troca de valor/estado
        static let hover  = Animation.snappy(duration: 0.12)
        static let fadeIn  = Animation.easeOut(duration: 0.18)
        static let fadeOut = Animation.easeIn(duration: 0.12)
        static let fill    = Animation.easeOut(duration: 0.8)                // anéis enchendo
        static let crossfade = Animation.easeInOut(duration: 0.3)

        /// Conteúdo chega depois da forma (follow-through).
        static let contentDelay: Double = 0.14
        /// Ambiente: lento e sutil.
        static func ambient(_ seconds: Double) -> Animation {
            .easeInOut(duration: seconds).repeatForever(autoreverses: true)
        }

        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        static func pick(_ a: Animation) -> Animation { reduced ? .easeInOut(duration: 0.18) : a }
    }

    // MARK: Tipografia (4 tamanhos: 15 / 13 / 11 / 10)
    enum Font {
        static let title    = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body     = SwiftUI.Font.system(size: 11, weight: .medium)
        static let caption  = SwiftUI.Font.system(size: 10, weight: .semibold)
        static let value    = SwiftUI.Font.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()
        static let display  = SwiftUI.Font.system(size: 32, weight: .semibold, design: .rounded)
        static func icon(_ size: CGFloat) -> SwiftUI.Font { .system(size: size, weight: .semibold) }
    }

    // MARK: Cores
    enum Palette {
        static let primary   = Color.white
        static let secondary = Color.white.opacity(0.62)
        static let tertiary  = Color.white.opacity(0.38)
        static let track     = Color.white.opacity(0.16)
        static let hover     = Color.white.opacity(0.12)
        static let safe      = Color.green
        static let warning   = Color.orange
        static let danger    = Color.red

        static func battery(_ level: Int?) -> Color {
            guard let l = level else { return tertiary }
            return l <= 20 ? danger : (l <= 40 ? warning : safe)
        }
    }

    // MARK: Raios e medidas
    enum Metric {
        static let closed: (top: CGFloat, bottom: CGFloat) = (6, 14)
        static let wings:  (top: CGFloat, bottom: CGFloat) = (8, 14)
        static let open:   (top: CGFloat, bottom: CGFloat) = (16, 32)
        static let wing: CGFloat = 44            // largura de cada "asa" ao lado do notch
        static let panelWidth: CGFloat = 440
        static let panelPadding: CGFloat = 20
        static let card: CGFloat = 24
        static func artRadius(_ size: CGFloat) -> CGFloat { size * 0.2 }
    }

    // MARK: Vidro
    enum Glass {
        // Corpo preto, vidro tipo água só na borda (como a Siri).
        static let rim: CGFloat = 6
        static let lens: CGFloat = 12      // base de lente transparente (mais grossa que as laterais)
        static var supported: Bool {
            if #available(macOS 26.0, *) { return true }
            return false
        }
        static var enabled: Bool { UserDefaults.standard.object(forKey: "liquidGlass") as? Bool ?? true }
    }
}

// MARK: - Animações contínuas (Core Animation)

enum Anim {
    /// Ritmo das animações que ficam rodando (ondinhas, bolinhas): suave e econômico.
    static let calm = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
}

// MARK: - Vidro único para todo o app

enum GlassStyle { case island, clear }

extension View {
    /// `.island`: vidro escurecido (notch, aviso). `.clear`: vidro transparente (tela de bloqueio).
    /// Sem Liquid Glass (ou desligado): preto na ilha, material do sistema na tela de bloqueio.
    @ViewBuilder func dsGlass<S: InsettableShape>(_ shape: S, _ style: GlassStyle = .island, enabled: Bool = true) -> some View {
        if #available(macOS 26.0, *), enabled {
            switch style {
            // água: transparente e refrativa. Sem a animação própria de "materializar":
            // o vidro aparece/some no mesmo instante da forma (não fica fantasma atrasado).
            case .island: self.glassEffect(.clear, in: shape).glassEffectTransition(.identity)
            case .clear:  self.glassEffect(.clear, in: shape)
            }
        } else {
            switch style {
            case .island: self.background(shape.fill(Color.black))
            case .clear:
                self.background(shape.fill(.ultraThinMaterial)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .environment(\.colorScheme, .dark))
            }
        }
    }
}

extension View {
    /// Sombra leve para texto/ícones brancos continuarem legíveis sobre vidro transparente.
    func legibleOnGlass() -> some View { shadow(color: .black.opacity(0.35), radius: 2.5, y: 0.5) }
}

extension AnyTransition {
    /// Texto/conteúdo trocando: entra desfocado e ganha nitidez (como na Siri).
    static var dsBlur: AnyTransition { AnyTransition(.blurReplace).combined(with: .scale(scale: 0.96, anchor: .top)) }
}

/// Corpo preto da ilha — UMA peça só, sempre a mesma: só os pontos do degradê mudam.
/// (Trocar de peça fazia o SwiftUI cruzar duas versões com transparência no meio da
/// transformação: era a "caixa fantasma".)
///  - solid: preto inteiro (durante a transformação)
///  - solidHeight: preto no topo, vidro de baixo para cima (expandida)
///  - nenhum: pontinhas de vidro nas laterais (parada/compacta)
struct LensBody<S: Shape>: View {
    let shape: S
    var lensStart: CGFloat? = nil      // compatibilidade (não usado)
    var solidWidth: CGFloat? = nil
    var solidHeight: CGFloat? = nil
    var solid = false

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1), h = max(g.size.height, 1)
            let vertical = solidHeight != nil
            let stops = gradientStops(w: w, h: h)
            shape
                .fill(Color.black)
                .mask(LinearGradient(stops: stops,
                                     startPoint: vertical ? .top : .leading,
                                     endPoint: vertical ? .bottom : .trailing)
                        // o degradê troca na hora (animar girava ele na diagonal = faixas claras)
                        .transaction { $0.animation = nil })
        }
        .allowsHitTesting(false)
    }

    /// (opacidade do preto, posição) de cada ponto do degradê
    func stopsFor(w: CGFloat, h: CGFloat) -> [(opacity: Double, location: CGFloat)] {
        let ops: [Double]
        let locs = gradientStops(w: w, h: h).map(\.location)
        if solid { ops = Array(repeating: 1, count: 6) }
        else if solidHeight != nil { ops = [1, 1, 1, 0.35, 0, 0] }
        else { ops = [0, 0.6, 1, 1, 0.6, 0] }
        return zip(ops, locs).map { ($0, $1) }
    }

    private func gradientStops(w: CGFloat, h: CGFloat) -> [Gradient.Stop] {
        // sempre 6 pontos, para o degradê poder animar entre estados
        if solid {
            return [0, 0.2, 0.4, 0.6, 0.8, 1].map { .init(color: .black, location: $0) }
        }
        if let solidH = solidHeight {
            let a = min(0.9, solidH / h)
            let b = min(1, a + max(0.18, 26 / h))
            return [
                .init(color: .black, location: 0),
                .init(color: .black, location: a * 0.5),
                .init(color: .black, location: a),
                .init(color: .black.opacity(0.35), location: a + (b - a) * 0.5),
                .init(color: .black.opacity(0), location: b),
                .init(color: .black.opacity(0), location: 1),
            ]
        }
        let edge: CGFloat = solidWidth.map { min(0.48, max(0.04, (w - $0) / 2 / w)) } ?? min(34, w * 0.14) / w
        return [
            .init(color: .black.opacity(0), location: 0),
            .init(color: .black.opacity(0.6), location: edge * 0.45),
            .init(color: .black, location: edge),
            .init(color: .black, location: 1 - edge),
            .init(color: .black.opacity(0.6), location: 1 - edge * 0.45),
            .init(color: .black.opacity(0), location: 1),
        ]
    }
}

/// Máscara do vidro: o inverso do preto — vidro só nas pontas (parada) ou na base (expandida).
/// Fica por CIMA de um corpo preto sempre inteiro; então, no pior caso, a ilha é preta, nunca vazia.
struct GlassMask: View {
    var solidWidth: CGFloat? = nil
    var solidHeight: CGFloat? = nil
    var body: some View {
        GeometryReader { g in
            let stops = LensBody(shape: Rectangle(), solidWidth: solidWidth, solidHeight: solidHeight)
                .stopsFor(w: max(g.size.width, 1), h: max(g.size.height, 1))
                .map { Gradient.Stop(color: .black.opacity(1 - $0.opacity), location: $0.location) }
            LinearGradient(stops: stops,
                           startPoint: solidHeight != nil ? .top : .leading,
                           endPoint: solidHeight != nil ? .bottom : .trailing)
                .transaction { $0.animation = nil }
        }
    }
}

/// Vidro sincronizado com a forma: material desfocado + brilho de "água" na borda.
/// Diferente do Liquid Glass do sistema, é uma camada comum: anima no mesmo quadro que a forma.
struct SyncedGlass<S: Shape>: View {
    let shape: S
    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(
                // brilho líquido: luz entrando por cima e reflexo suave embaixo
                shape.fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.10), location: 0),
                    .init(color: .white.opacity(0.0), location: 0.45),
                    .init(color: .white.opacity(0.08), location: 1),
                ], startPoint: .top, endPoint: .bottom))
                .blendMode(.plusLighter)
            )
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
    }
}

/// Container que funde peças de vidro próximas como líquido.
struct LiquidContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Peças compartilhadas

/// Foto do fone (se existir) ou símbolo.
struct DeviceGlyph: View {
    let name: String
    var width: CGFloat
    var body: some View {
        if let img = deviceImage(for: name) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: width, height: width * 0.7)
        } else {
            Image(systemName: budsSymbol(for: name))
                .font(.system(size: width * 0.55, weight: .semibold))
                .foregroundStyle(DS.Palette.primary)
                .frame(width: width, height: width * 0.7)
        }
    }
}

/// Anel de bateria (estilo MagSafe): enche ao aparecer e pulsa uma vez.
/// Use `content` para colocar o fone no meio, ou `showsValue` para o número.
struct BatteryRing<Content: View>: View {
    let level: Int?
    var size: CGFloat = 40
    var line: CGFloat = 3
    var showsValue = false
    var pulse = false
    @ViewBuilder var content: Content

    @State private var fill: CGFloat = 0
    @State private var pulsed = false

    var body: some View {
        let color = DS.Palette.battery(level)
        ZStack {
            if pulse {
                Circle().stroke(color.opacity(pulsed ? 0 : 0.6), lineWidth: line * 0.8)
                    .scaleEffect(pulsed ? 1.45 : 1)
            }
            Circle().stroke(DS.Palette.track, lineWidth: line)
            Circle().trim(from: 0, to: fill)
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.55), radius: line)
            if showsValue, let level {
                Text("\(level)").font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(DS.Palette.primary)
            } else {
                content
            }
        }
        .frame(width: size, height: size)
        .onAppear(perform: animate)
        .onChange(of: level) { _, _ in animate() }
    }

    private func animate() {
        let target = CGFloat(level ?? 0) / 100
        if DS.Motion.reduced { fill = target; return }
        fill = 0; pulsed = false
        withAnimation(DS.Motion.fill.delay(0.1)) { fill = target }
        if pulse { withAnimation(.easeOut(duration: 0.7).delay(0.85)) { pulsed = true } }
    }
}

extension BatteryRing where Content == EmptyView {
    init(level: Int?, size: CGFloat = 40, line: CGFloat = 3, showsValue: Bool = false, pulse: Bool = false) {
        self.init(level: level, size: size, line: line, showsValue: showsValue, pulse: pulse) { EmptyView() }
    }
}

/// Capa do álbum (ou nota musical), com raio proporcional.
struct Artwork: View {
    let image: NSImage?
    var size: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Metric.artRadius(size), style: .continuous)
        ZStack {
            shape.fill(DS.Palette.track)
            if let image {
                Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.38))
                    .foregroundStyle(DS.Palette.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .animation(DS.Motion.crossfade, value: image != nil)
    }
}

/// Tradução (pt = idioma base; en em en.lproj/Localizable.strings).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func LF(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }

/// "60%" sempre do mesmo jeito.
func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }

/// Botão de ícone redondo (controles de música etc.).
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 14
    var help: String = ""
    let action: () -> Void
    @State private var hover = false
    @State private var taps = 0
    var body: some View {
        Button { taps += 1; action() } label: {
            Image(systemName: symbol).font(DS.Font.icon(size))
                .foregroundStyle(DS.Palette.primary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: taps)
                .frame(width: size + 14, height: size + 14)
                .background(Circle().fill(hover ? DS.Palette.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Motion.hover) { hover = h } }
        .help(help)
    }
}
