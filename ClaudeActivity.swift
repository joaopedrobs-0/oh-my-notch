// Mostra na ilha o que o Claude Code está fazendo.
// Os hooks do Claude Code (claude-hook.sh) anexam cada evento em ~/.ohmynotch/claude-events.log;
// aqui acompanhamos esse arquivo e traduzimos o evento numa frase curta.

import SwiftUI
import AppKit

final class ClaudeActivity: ObservableObject {
    static let shared = ClaudeActivity()

    enum Phase: Equatable { case idle, thinking, working, waiting, done }

    @Published var phase: Phase = .idle
    @Published var text = ""
    @Published var symbol = "sparkle"
    /// A cúpula grande só fica 3 s; depois o "pensando" vira as asas compactas.
    @Published var domeVisible = false
    private var domeWork: DispatchWorkItem?

    var active: Bool { phase != .idle }
    /// Pausa (para gravar outras animações sem a ilha do Claude na frente)
    var paused = false { didSet { if paused { withAnimation(DS.Motion.swap) { phase = .idle } } } }

    func debugSet(_ p: Phase, _ t: String) {
        paused = false
        set(p, t, p == .done ? "checkmark.circle.fill" : "sparkle")
        if p == .done { scheduleIdle(after: 3) }
    }

    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ohmynotch")
    private var url: URL { dir.appendingPathComponent("claude-events.log") }
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var offset: UInt64 = 0
    private var buffer = ""
    private var idleWork: DispatchWorkItem?

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        // começa do fim: eventos antigos não interessam
        offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        watch()
    }

    private func watch() {
        source?.cancel()
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let ev = src.data
            if ev.contains(.delete) || ev.contains(.rename) {
                self.offset = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.watch() }
                return
            }
            self.readNew()
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
    }

    private func readNew() {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 }              // arquivo foi zerado
        try? h.seek(toOffset: offset)
        let data = h.readDataToEndOfFile()
        offset += UInt64(data.count)
        buffer += String(decoding: data, as: UTF8.self)
        let parts = buffer.components(separatedBy: "\u{1E}")
        buffer = parts.last ?? ""
        for chunk in parts.dropLast() {
            let json = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                handle(obj)
            }
        }
        // mantém o arquivo pequeno
        if offset > 512_000 { try? Data().write(to: url); offset = 0 }
    }

    // MARK: Tradução do evento

    private func handle(_ e: [String: Any]) {
        guard !paused else { return }
        let event = e["hook_event_name"] as? String ?? ""
        switch event {
        case "UserPromptSubmit":
            set(.thinking, L("Pensando…"), "sparkle")
        case "PreToolUse":
            let tool = e["tool_name"] as? String ?? ""
            let input = e["tool_input"] as? [String: Any] ?? [:]
            // perguntas para você: fica o aviso discreto até você responder
            if tool == "AskUserQuestion" || tool == "ExitPlanMode" ||
               (tool.contains("wrap_up") && !((input["ask"] as? String) ?? "").isEmpty) {
                set(.waiting, L("Esperando sua resposta"), "exclamationmark.bubble.fill")
                return
            }
            let (t, s) = describe(tool: tool, input: input)
            set(.working, t, s)
        case "PostToolUse":
            // sem nova ação logo em seguida = o Claude voltou a pensar/escrever
            scheduleThinking()
        case "Notification":
            let msg = (e["message"] as? String) ?? ""
            set(.waiting, msg.lowercased().contains("permission") || msg.lowercased().contains("permiss")
                ? L("Esperando sua permissão") : L("Esperando sua resposta"), "exclamationmark.bubble.fill")
        case "Stop", "SubagentStop":
            if event == "Stop" {
                // se terminou com uma pergunta, o aviso continua até você responder
                if phase == .waiting { return }
                let last = (e["last_assistant_message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let transcript = e["transcript_path"] as? String
                set(.done, L("Pronto"), "checkmark.circle.fill")
                scheduleIdle(after: 3)
                // a pergunta do fim da resposta (botões) não passa pelos hooks: confere na conversa salva
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let asked = last.hasSuffix("?") || Self.turnEndedWithQuestion(transcript)
                    DispatchQueue.main.async {
                        guard let self, asked, self.phase == .done else { return }
                        self.set(.waiting, L("Esperando sua resposta"), "exclamationmark.bubble.fill")
                    }
                }
            }
        default: break
        }
    }

    private var thinkWork: DispatchWorkItem?

    private func scheduleThinking() {
        thinkWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .working else { return }
            self.set(.thinking, L("Pensando…"), "sparkle")
        }
        thinkWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }

    /// Lê o fim da conversa salva e vê se, depois da sua última mensagem, eu deixei uma pergunta.
    static func turnEndedWithQuestion(_ path: String?) -> Bool {
        guard let path, let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            // sua última mensagem: daqui para trás já é outro turno
            if line.contains("\"role\":\"user\",\"content\":\"") { return false }
            if line.contains("mcp__ccd_turn__wrap_up") || line.contains("AskUserQuestion"),
               let d = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let msg = obj["message"] as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                for c in content where (c["type"] as? String) == "tool_use" {
                    let name = c["name"] as? String ?? ""
                    let input = c["input"] as? [String: Any] ?? [:]
                    if name == "AskUserQuestion" { return true }
                    if name.contains("wrap_up"), let ask = input["ask"] as? String, !ask.isEmpty { return true }
                }
            }
        }
        return false
    }

    private func set(_ p: Phase, _ t: String, _ s: String) {
        idleWork?.cancel()
        if p == .thinking && phase != .thinking {
            domeVisible = true
            domeWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.domeVisible = false }
            domeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
        } else if p != .thinking {
            domeWork?.cancel(); domeVisible = false
        }
        if p != .thinking { thinkWork?.cancel() }
        withAnimation(DS.Motion.swap) { phase = p; text = t; symbol = s }
        if p == .working || p == .thinking { scheduleIdle(after: 180) }   // segurança: some se o Claude parar sem avisar
        if p == .waiting { scheduleIdle(after: 3600) }                   // aviso fica até você responder (máx. 1 h)
    }

    private func scheduleIdle(after s: Double) {
        idleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in withAnimation(DS.Motion.swap) { self?.phase = .idle } }
        idleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    private func file(_ input: [String: Any]) -> String {
        let p = (input["file_path"] as? String) ?? (input["path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
        return (p as NSString).lastPathComponent
    }

    private func describe(tool: String, input: [String: Any]) -> (String, String) {
        switch tool {
        case "Edit", "MultiEdit": return (LF("Editando %@", file(input)), "pencil")
        case "Write": return (LF("Escrevendo %@", file(input)), "square.and.pencil")
        case "Read": return (LF("Lendo %@", file(input)), "doc.text")
        case "NotebookEdit": return (L("Editando notebook"), "pencil")
        case "Bash":
            if let d = input["description"] as? String, !d.isEmpty { return (d, "terminal") }
            return (L("Rodando comando"), "terminal")
        case "Grep", "Glob": return (L("Procurando no código"), "magnifyingglass")
        case "WebSearch": return (L("Pesquisando na web"), "globe")
        case "WebFetch": return (L("Lendo uma página"), "globe")
        case "Task", "Agent": return (L("Delegando uma tarefa"), "person.2")
        case "TodoWrite": return (L("Organizando o plano"), "checklist")
        case "Skill": return (L("Usando uma skill"), "wand.and.stars")
        default:
            if tool.contains("computer-use") { return (L("Usando o computador"), "cursorarrow.motionlines") }
            if tool.contains("Browser") || tool.contains("chrome") { return (L("Usando o navegador"), "safari") }
            if tool.contains("update_plan") { return (L("Atualizando o plano"), "checklist") }
            if tool.contains("wrap_up") { return (L("Finalizando"), "flag.checkered") }
            if tool.hasPrefix("mcp__") { return (L("Usando uma ferramenta"), "puzzlepiece.extension") }
            return (L("Trabalhando"), "sparkle")
        }
    }
}

// MARK: - Ilha: Live Activity do Claude
// Linguagem tirada da Siri (iOS 27), sem copiar: luz líquida quando pensa,
// anel de bolinhas quando age, texto entrando com desfoque, luz que se condensa entre fases.

enum ClaudePalette {
    static let warm: [Color] = [
        Color(red: 1.0, green: 0.78, blue: 0.55),   // pêssego
        Color(red: 0.95, green: 0.48, blue: 0.32),  // coral (laranja do Claude)
        Color(red: 0.98, green: 0.62, blue: 0.2),   // âmbar
        Color(red: 0.85, green: 0.35, blue: 0.55),  // rosa
        Color(red: 0.55, green: 0.4, blue: 0.95),   // violeta
    ]
    static let accent = Color(red: 0.92, green: 0.52, blue: 0.36)
}

/// Fita de luz líquida: duas ondas que se cruzam e fluem (fase "pensando").
struct ClaudeRibbon: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: DS.Motion.reduced)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let mid = size.height * 0.5
                func band(phase: Double, amp: CGFloat, thick: CGFloat, colors: [Color]) {
                    var top = Path(), bottom = Path()
                    let steps = 48
                    for i in 0...steps {
                        let x = size.width * CGFloat(i) / CGFloat(steps)
                        let u = Double(i) / Double(steps)
                        let env = CGFloat(sin(.pi * u))                         // afina nas pontas
                        let y = mid + amp * env * CGFloat(sin(u * 2 * .pi * 1.1 + phase))
                        let th = thick * env * (0.6 + 0.4 * CGFloat(sin(u * 3 + phase * 0.7)))
                        let pt = CGPoint(x: x, y: y - th), pb = CGPoint(x: x, y: y + th)
                        if i == 0 { top.move(to: pt); bottom.move(to: pb) } else { top.addLine(to: pt); bottom.addLine(to: pb) }
                    }
                    var shape = top
                    for p in bottom.reversedPoints() { shape.addLine(to: p) }
                    shape.closeSubpath()
                    g.fill(shape, with: .linearGradient(Gradient(colors: colors),
                                                        startPoint: CGPoint(x: 0, y: mid), endPoint: CGPoint(x: size.width, y: mid)))
                }
                // (o desfoque fica no modificador da view: na GPU. Dentro do Canvas era feito pela CPU)
                g.blendMode = .plusLighter
                band(phase: t * 2.2, amp: 5, thick: 4.5, colors: ClaudePalette.warm)
                band(phase: -t * 1.7 + 1.5, amp: 5, thick: 3.5, colors: ClaudePalette.warm.reversed())
                // núcleo branco onde as ondas se cruzam
                band(phase: t * 2.2, amp: 5, thick: 1.2, colors: [.clear, .white.opacity(0.85), .clear])
            }
            .blur(radius: 3)
        }
        .allowsHitTesting(false)
    }
}

private extension Path {
    /// Pontos da borda de baixo, do fim para o começo (para fechar a fita).
    func reversedPoints() -> [CGPoint] {
        var pts: [CGPoint] = []
        forEach { el in
            switch el {
            case .move(let p), .line(let p): pts.append(p)
            default: break
            }
        }
        return pts.reversed()
    }
}

/// Anel de 7 bolinhas brilhantes girando, com brilho correndo (fase "agindo").
/// Feito em Core Animation: anima no servidor de desenho do macOS, quase sem CPU do app
/// (a versão em SwiftUI redesenhava 30x por segundo enquanto o Claude trabalhava).
struct ClaudeDots: NSViewRepresentable {
    var size: CGFloat = 18
    var color: Color = ClaudePalette.accent
    func makeNSView(context: Context) -> DotsView { DotsView(size: size, glow: NSColor(color)) }
    func updateNSView(_ v: DotsView, context: Context) { v.setAnimating(!DS.Motion.reduced) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotsView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class DotsView: NSView {
    private let replicator = CAReplicatorLayer()
    private let dot = CALayer()
    private let s: CGFloat
    private var animating: Bool?

    init(size: CGFloat, glow: NSColor) {
        s = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        replicator.frame = bounds
        replicator.instanceCount = 7
        replicator.instanceTransform = CATransform3DMakeRotation(2 * .pi / 7, 0, 0, 1)
        replicator.instanceDelay = 0.9 / 7
        let d = size * 0.22
        dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        dot.position = CGPoint(x: size / 2, y: size / 2 + size * 0.38)
        dot.cornerRadius = d / 2
        dot.backgroundColor = NSColor.white.cgColor
        dot.shadowColor = glow.cgColor
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
        dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)   // sombra com forma pronta: bem mais barata
        dot.opacity = 0.5
        replicator.addSublayer(dot)
        layer?.addSublayer(replicator)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: s, height: s) }

    func setAnimating(_ on: Bool) {
        guard on != animating else { return }
        animating = on
        dot.removeAllAnimations(); replicator.removeAllAnimations()
        guard on else { return }
        // brilho que corre pelo anel
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [1.0, 0.35, 0.35]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 0.9
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")
        let grow = CAKeyframeAnimation(keyPath: "transform.scale")
        grow.values = [1.25, 0.8, 0.8]
        grow.keyTimes = [0, 0.5, 1]
        grow.duration = 0.9
        grow.repeatCount = .infinity
        dot.add(grow, forKey: "grow")
        // o anel inteiro gira devagar
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0; spin.toValue = 2 * Double.pi
        spin.duration = 4.5
        spin.repeatCount = .infinity
        replicator.add(spin, forKey: "spin")
        // 30 quadros por segundo bastam para um anel pequeno (metade do trabalho de desenho)
        for a in [pulse, grow] as [CAAnimation] { a.preferredFrameRateRange = Anim.calm }
        spin.preferredFrameRateRange = Anim.calm
        dot.add(pulse, forKey: "pulse"); dot.add(grow, forKey: "grow"); replicator.add(spin, forKey: "spin")
    }
}

/// Fase "pensando": cúpula preta com lente embaixo e a fita de luz na divisa.
struct ClaudeThinkContent: View {
    @ObservedObject var model: IslandModel
    @State private var lit = false
    var body: some View {
        let notchH = max(model.notch.height, 32)
        ZStack(alignment: .top) {
            // pontinho que acende no topo (está "ouvindo")
            Circle().fill(ClaudePalette.accent)
                .frame(width: 5, height: 5)
                .shadow(color: ClaudePalette.accent, radius: 4)
                .offset(y: notchH + 4)
                .opacity(lit ? 0 : 1)
            ClaudeRibbon()
                .frame(height: 26)
                .padding(.horizontal, 22)
                .offset(y: notchH + 4)
                .opacity(lit ? 1 : 0)
                .scaleEffect(x: lit ? 1 : 0.2, y: 1)
        }
        .onAppear {
            // a luz nasce como um traço branco e abre em fita (~300 ms)
            withAnimation(.easeOut(duration: 0.45).delay(0.18)) { lit = true }
        }
    }
}

/// Fase "agindo" (e "esperando"/"pronto"): anel de bolinhas + texto com desfoque.
struct ClaudeLiveContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var c = ClaudeActivity.shared
    @State private var bloom = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Group {
                    switch c.phase {
                    case .done:
                        Image(systemName: "checkmark").font(DS.Font.icon(12)).foregroundStyle(DS.Palette.safe)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    case .waiting:
                        // discreto: sem piscar, só um símbolo de alerta com um brilho suave
                        Image(systemName: "exclamationmark.bubble.fill").font(DS.Font.icon(12))
                            .foregroundStyle(ClaudePalette.accent)
                            .shadow(color: ClaudePalette.accent.opacity(0.5), radius: 3)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    default:
                        // a luz da fase anterior chega como um ponto e floresce no anel
                        ClaudeDots(size: 18)
                            .scaleEffect(bloom ? 1 : 0.15)
                            .opacity(bloom ? 1 : 0.6)
                    }
                }
                .frame(width: 18, height: 18)
                Text("Claude").font(DS.Font.body.weight(.semibold)).foregroundStyle(DS.Palette.primary)
            }
            .frame(width: IslandModel.claudeWing, alignment: .leading)
            .padding(.leading, 10)
            Spacer(minLength: model.notch.width)
            Text(c.text)
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .id(c.text)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 5)),
                                        removal: .opacity.combined(with: .offset(y: -5))))   // sem desfoque: desfoque de texto custa CPU
                .font(DS.Font.caption)
                .frame(width: IslandModel.claudeWing, alignment: .trailing)
                .padding(.trailing, 10)
        }
        .frame(height: max(model.notch.height, 32))
        .animation(DS.Motion.swap, value: c.text)
        .animation(DS.Motion.pop, value: c.phase)
        .onAppear { withAnimation(DS.Motion.pop.delay(0.08)) { bloom = true } }
    }
}
