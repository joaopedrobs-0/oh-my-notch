// Recursos extras da ilha: abas (Início, Tarefas, Timer, Estante, Sistema),
// aviso de carregamento/bateria do Mac e avisos genéricos (timer acabou, print salvo, notificações).
//
// Tudo feito do zero. Ideias vindas da análise do vídeo de comparação:
// - Tarefas que vão para o app Lembretes (a reclamação sobre o NotchNook)
// - Timer (Atoll, NotchNook)
// - Carregamento/bateria (NotchNook)
// - CPU/RAM (Atoll, Droppy)
// - Estante com a pasta de prints que VOCÊ escolhe (o app Screenshots obrigava a mudar o Mac)

import AppKit
import SwiftUI
import EventKit
import IOKit.ps
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - Abas da ilha

enum HomeTab: String, CaseIterable, Identifiable {
    case home, tasks, timer, shelf, stats
    var id: Self { self }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .tasks: return "checklist"
        case .timer: return "timer"
        case .shelf: return "tray.full.fill"
        case .stats: return "cpu"
        }
    }
    var title: String {
        switch self {
        case .home: return L("Início")
        case .tasks: return L("Tarefas")
        case .timer: return L("Timer")
        case .shelf: return L("Estante")
        case .stats: return L("Sistema")
        }
    }
    var enabled: Bool {
        switch self {
        case .home: return true
        case .tasks: return Features.tasks
        case .timer: return Features.timer
        case .shelf: return Features.shelf
        case .stats: return Features.stats
        }
    }
    static var visible: [HomeTab] { allCases.filter(\.enabled) }
}

struct TabBar: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        let tabs = HomeTab.visible
        if tabs.count > 1 {
            HStack(spacing: 2) {
                ForEach(tabs) { t in TabButton(tab: t, selected: model.tab == t) { model.select(t) } }
            }
        }
    }
}

struct TabButton: View {
    let tab: HomeTab
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? DS.Palette.primary : (hover ? DS.Palette.secondary : DS.Palette.tertiary))
                .frame(width: 22, height: 20)
                .background(Capsule().fill(selected ? Color.white.opacity(0.16) : (hover ? DS.Palette.hover : .clear)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .onHover { h in withAnimation(DS.Motion.hover) { hover = h } }
        .animation(DS.Motion.swap, value: selected)
    }
}

/// Conteúdo da aba escolhida.
struct TabContent: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        Group {
            switch model.tab {
            case .home: HomeContent()
            case .tasks: TasksView(model: model)
            case .timer: TimerView()
            case .shelf: ShelfView(model: model)
            case .stats: StatsView()
            }
        }
        .id(model.tab)
        .transition(.opacity.combined(with: .offset(y: 3)))
    }
}

/// Caixa padrão das abas: mesma margem e altura que a música/calendário.
struct TabPanel<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 64, alignment: .leading)
            .padding(.horizontal, DS.Metric.panelPadding)
            .padding(.bottom, 14)
    }
}

// MARK: - Tarefas (app Lembretes)

final class TasksFeed: ObservableObject {
    static let shared = TasksFeed()
    struct Item: Identifiable, Equatable { let id: String; let title: String; let due: Date?; let color: Color }

    @Published var items: [Item] = []
    @Published var total = 0
    @Published var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    private let store = EKEventStore()
    private var started = false
    var authorized: Bool { access == .fullAccess }

    func start() {
        guard !started else { load(); return }
        started = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.load()
        }
        if access == .notDetermined { request() } else { load() }
    }

    func request() {
        store.requestFullAccessToReminders { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.access = EKEventStore.authorizationStatus(for: .reminder)
                self?.load()
            }
        }
    }

    func load() {
        access = EKEventStore.authorizationStatus(for: .reminder)
        guard authorized else { items = []; return }
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: pred) { [weak self] rs in
            let sorted = (rs ?? []).sorted { a, b in
                let da = a.dueDateComponents?.date ?? .distantFuture, db = b.dueDateComponents?.date ?? .distantFuture
                if da != db { return da < db }
                return (a.creationDate ?? .distantPast) > (b.creationDate ?? .distantPast)
            }
            let items = sorted.prefix(3).map { r in
                Item(id: r.calendarItemIdentifier, title: r.title ?? "", due: r.dueDateComponents?.date,
                     color: Color(nsColor: r.calendar?.color ?? .systemOrange))
            }
            DispatchQueue.main.async { self?.items = Array(items); self?.total = rs?.count ?? 0 }
        }
    }

    func complete(_ id: String) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        r.isCompleted = true
        try? store.save(r, commit: true)
        withAnimation(DS.Motion.swap) { items.removeAll { $0.id == id } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.load() }
    }

    func add(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, authorized, let cal = store.defaultCalendarForNewReminders() else { return }
        let r = EKReminder(eventStore: store)
        r.title = t
        r.calendar = cal
        try? store.save(r, commit: true)
        load()
    }

    func openApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

struct TasksView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var feed = TasksFeed.shared
    @State private var adding = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TabPanel {
            if !feed.authorized {
                PermissionPrompt(symbol: "checklist", text: L("Mostre e crie tarefas do app Lembretes aqui."),
                                 button: L("Permitir Lembretes")) {
                    if feed.access == .notDetermined { feed.request() }
                    else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!) }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        if adding {
                            HStack(spacing: 8) {
                                Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(DS.Palette.tertiary)
                                TextField(L("Nova tarefa"), text: $text)
                                    .textFieldStyle(.plain).font(DS.Font.body).foregroundStyle(DS.Palette.primary)
                                    .focused($focused)
                                    .onSubmit { feed.add(text); text = ""; finish() }
                                    .onExitCommand { finish() }
                            }
                            .frame(height: 19)
                        }
                        ForEach(feed.items.prefix(adding ? 2 : 3)) { item in TaskRow(item: item) }
                        if feed.items.isEmpty && !adding {
                            Text(L("Nenhuma tarefa pendente")).font(DS.Font.body).foregroundStyle(DS.Palette.secondary)
                                .frame(height: 19)
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(spacing: 2) {
                        IconButton(symbol: adding ? "xmark" : "plus", size: 12, help: L("Nova tarefa")) {
                            if adding { finish() } else { startAdding() }
                        }
                        IconButton(symbol: "arrow.up.forward.app", size: 11, help: L("Abrir Lembretes")) { feed.openApp() }
                    }
                }
            }
        }
        .onAppear { feed.start() }
    }

    private func startAdding() {
        adding = true
        IslandController.shared.beginTyping()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }
    private func finish() {
        adding = false; focused = false; text = ""
        IslandController.shared.endTyping()
    }
}

struct TaskRow: View {
    let item: TasksFeed.Item
    @State private var done = false
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(DS.Motion.pop) { done = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { TasksFeed.shared.complete(item.id) }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : (hover ? "circle.inset.filled" : "circle"))
                    .font(.system(size: 12))
                    .foregroundStyle(done ? item.color : (hover ? item.color.opacity(0.8) : DS.Palette.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(DS.Motion.hover) { hover = h } }
            .help(L("Concluir"))
            Text(item.title).font(DS.Font.body)
                .foregroundStyle(done ? DS.Palette.tertiary : DS.Palette.primary)
                .strikethrough(done, color: DS.Palette.tertiary)
                .lineLimit(1)
            if let due = item.due {
                Text(due, format: .dateTime.day().month(.abbreviated))
                    .font(DS.Font.caption)
                    .foregroundStyle(due < Date() ? DS.Palette.danger : DS.Palette.tertiary)
            }
        }
        .frame(height: 19)
    }
}

struct PermissionPrompt: View {
    let symbol: String, text: String, button: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(DS.Palette.secondary)
                .frame(width: 32)
            Text(text).font(DS.Font.body).foregroundStyle(DS.Palette.secondary).lineLimit(2)
            Spacer(minLength: 6)
            Button(action: action) {
                Text(button).font(DS.Font.caption).foregroundStyle(DS.Palette.primary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(DS.Palette.track))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Timer

final class TimerModel: ObservableObject {
    static let shared = TimerModel()
    @Published private(set) var total: TimeInterval = 5 * 60
    @Published private(set) var remaining: TimeInterval = 5 * 60
    @Published private(set) var running = false
    private var end: Date?
    private var tick: Timer?

    var active: Bool { running || remaining < total }      // começou (rodando ou pausado)
    var progress: Double { total > 0 ? max(0, min(1, 1 - remaining / total)) : 0 }

    func set(minutes: Int) {
        stopTick()
        total = TimeInterval(minutes * 60); remaining = total; running = false
        IslandController.shared.timerChanged()
    }
    func add(minutes: Int) {
        total += TimeInterval(minutes * 60); remaining += TimeInterval(minutes * 60)
        if running { end = Date().addingTimeInterval(remaining) }
    }
    func toggle() { running ? pause() : startTimer() }
    func startTimer() {
        guard remaining > 0 else { return }
        end = Date().addingTimeInterval(remaining)
        running = true
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.update() }
        tick?.tolerance = 0.1
        IslandController.shared.timerChanged()
    }
    func pause() {
        update(); stopTick(); running = false
        IslandController.shared.timerChanged()
    }
    func reset() {
        stopTick(); running = false; remaining = total
        IslandController.shared.timerChanged()
    }
    private func stopTick() { tick?.invalidate(); tick = nil; end = nil }
    private func update() {
        guard let end else { return }
        let r = max(0, end.timeIntervalSinceNow.rounded(.up))
        if r != remaining { remaining = r }
        if r <= 0 { finished() }
    }
    private func finished() {
        stopTick(); running = false; remaining = total
        IslandController.shared.timerChanged()
        NSSound(named: "Glass")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { NSSound(named: "Glass")?.play() }
        IslandController.shared.showAlert(IslandAlert(symbol: "timer", color: .orange,
                                                      title: L("Timer acabou"),
                                                      subtitle: Self.format(total)), duration: 8)
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct TimerView: View {
    @ObservedObject var t = TimerModel.shared
    var body: some View {
        TabPanel {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(DS.Palette.track, lineWidth: 4)
                    Circle().trim(from: 0, to: t.progress)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: t.progress)
                    Button { t.toggle() } label: {
                        Image(systemName: t.running ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(Color.orange)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 40, height: 40).contentShape(Circle())
                    }
                    .buttonStyle(.plain).help(t.running ? L("Pausar") : L("Iniciar"))
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 4) {
                    Text(TimerModel.format(t.remaining))
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(DS.Palette.primary)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(DS.Motion.swap, value: t.remaining)
                    HStack(spacing: 5) {
                        ForEach([1, 5, 10, 25], id: \.self) { m in
                            Chip(text: "\(m)m", selected: !t.active && Int(t.total) == m * 60) { t.set(minutes: m) }
                        }
                    }
                }
                Spacer(minLength: 4)
                VStack(spacing: 2) {
                    IconButton(symbol: "plus", size: 11, help: L("Mais 1 minuto")) { t.add(minutes: 1) }
                    IconButton(symbol: "arrow.counterclockwise", size: 11, help: L("Zerar")) { t.reset() }
                }
            }
        }
    }
}

struct Chip: View {
    let text: String
    var selected = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(text).font(DS.Font.caption).monospacedDigit()
                .foregroundStyle(selected ? Color.black : DS.Palette.primary)
                .padding(.horizontal, 8).frame(height: 18)
                .background(Capsule().fill(selected ? Color.orange : (hover ? DS.Palette.hover.opacity(2) : DS.Palette.track)))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Motion.hover) { hover = h } }
    }
}

/// Asas com o timer rodando (como o timer no iPhone).
struct TimerLiveContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var t = TimerModel.shared
    var body: some View {
        WingsContent(model: model) {
            ZStack {
                Circle().stroke(Color.orange.opacity(0.25), lineWidth: 2.5)
                Circle().trim(from: 0, to: t.progress)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: t.running ? "timer" : "pause.fill").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.orange)
            }
            .frame(width: 18, height: 18)
        } trailing: {
            Text(TimerModel.format(t.remaining))
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(t.running ? Color.orange : DS.Palette.secondary)
                .contentTransition(.numericText(countsDown: true))
                .animation(DS.Motion.swap, value: t.remaining)
                .fixedSize()
        }
    }
}

// MARK: - Bateria e carregamento do Mac

final class PowerMonitor: ObservableObject {
    static let shared = PowerMonitor()
    @Published var level: Int?
    @Published var charging = false
    @Published var onAC = false
    @Published var hasBattery = false
    private var source: CFRunLoopSource?
    private var warned: Set<Int> = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        read(initial: true)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.read(initial: false) }
        }, ctx)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func read(initial: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let ac = type == kIOPMACPowerKey
        var lvl: Int?, chg = false, has = false
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            has = true
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                lvl = Int((Double(cur) / Double(max) * 100).rounded())
            }
            chg = d[kIOPSIsChargingKey] as? Bool ?? false
        }
        let pluggedNow = ac && !onAC && !initial
        hasBattery = has; level = lvl; charging = chg; onAC = ac
        guard has, Features.battery else { return }
        if pluggedNow {
            warned.removeAll()
            IslandController.shared.showCharging()
        }
        // bateria fraca: avisa uma vez em 20% e outra em 10%
        if !ac, let l = lvl {
            for th in [20, 10] where l <= th && !warned.contains(th) {
                warned.insert(th)
                if !initial || l <= 10 {
                    IslandController.shared.showAlert(IslandAlert(
                        symbol: l <= 10 ? "battery.0percent" : "battery.25percent", color: .red,
                        title: L("Bateria fraca"), subtitle: LF("%d%% restantes · conecte o carregador", l)), duration: 6)
                }
                break
            }
        }
        if ac { warned.removeAll() }
    }
}

/// Asas ao conectar o carregador: raio verde + porcentagem (como no iPhone).
struct ChargingContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var p = PowerMonitor.shared
    @State private var flash = 0
    var body: some View {
        WingsContent(model: model) {
            Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.green)
                .symbolEffect(.bounce, value: flash)
                .onAppear { flash += 1 }
        } trailing: {
            HStack(spacing: 5) {
                Text("\(p.level ?? 0)%").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.green)
                MiniBattery(level: p.level ?? 0, charging: true)
            }
            .fixedSize()
        }
    }
}

struct MiniBattery: View {
    let level: Int
    var charging = false
    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous).stroke(DS.Palette.tertiary, lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(charging ? Color.green : DS.Palette.battery(level))
                    .frame(width: max(2, 19 * CGFloat(level) / 100))
                    .padding(1.5)
            }
            .frame(width: 24, height: 11)
            RoundedRectangle(cornerRadius: 1).fill(DS.Palette.tertiary).frame(width: 1.5, height: 4)
        }
    }
}

// MARK: - Sistema (CPU, memória, bateria)

final class SystemStats: ObservableObject {
    static let shared = SystemStats()
    @Published var cpu: Double = 0       // 0...1
    @Published var memUsed: Double = 0   // bytes
    @Published var memTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    private var prev: host_cpu_load_info?
    private var timer: Timer?
    private var users = 0

    /// Só mede enquanto a aba está na tela (economia de energia).
    func attach() {
        users += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.sample() }
        timer?.tolerance = 0.3
    }
    func detach() {
        users = max(0, users - 1)
        if users == 0 { timer?.invalidate(); timer = nil; prev = nil }
    }

    private func sample() {
        // só mede com a aba Sistema realmente na tela (o onDisappear do SwiftUI nem sempre chega)
        let m = IslandController.shared.model
        guard m.mode == .home, m.tab == .stats, m.contentVisible else {
            users = 0; timer?.invalidate(); timer = nil; prev = nil; return
        }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            if let p = prev {
                let user = Double(info.cpu_ticks.0 &- p.cpu_ticks.0)
                let sys = Double(info.cpu_ticks.1 &- p.cpu_ticks.1)
                let idle = Double(info.cpu_ticks.2 &- p.cpu_ticks.2)
                let nice = Double(info.cpu_ticks.3 &- p.cpu_ticks.3)
                let total = user + sys + idle + nice
                if total > 0 { cpu = (user + sys + nice) / total }
            }
            prev = info
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let vr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            // igual ao "Memória usada" do Monitor de Atividade: app + com fio + comprimida
            let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
            let used = (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
            if abs(memUsed - used) > 20_000_000 { memUsed = used }   // só redesenha se mudou de verdade
        }
    }
}

struct StatsView: View {
    @ObservedObject var s = SystemStats.shared
    @ObservedObject var p = PowerMonitor.shared
    var body: some View {
        TabPanel {
            HStack(spacing: 0) {
                Gauge2(value: s.cpu, color: s.cpu > 0.8 ? .red : (s.cpu > 0.5 ? .orange : .blue),
                       label: "CPU", text: "\(Int((s.cpu * 100).rounded()))%")
                Spacer()
                let mem = s.memTotal > 0 ? s.memUsed / s.memTotal : 0
                Gauge2(value: mem, color: mem > 0.85 ? .red : (mem > 0.7 ? .orange : .purple),
                       label: L("Memória"), text: String(format: "%.1f GB", s.memUsed / 1_073_741_824))
                Spacer()
                if p.hasBattery {
                    Gauge2(value: Double(p.level ?? 0) / 100, color: p.charging ? .green : DS.Palette.battery(p.level),
                           label: p.charging ? L("Carregando") : L("Bateria"), text: "\(p.level ?? 0)%",
                           symbol: p.charging ? "bolt.fill" : nil)
                }
            }
            .padding(.horizontal, 10)
        }
        .onAppear { s.attach() }
        .onDisappear { s.detach() }
    }
}

struct Gauge2: View {
    let value: Double, color: Color, label: String, text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(DS.Palette.track, lineWidth: 4)
                Circle().trim(from: 0, to: max(0.01, min(1, value)))
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(color) }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text(text).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(DS.Palette.primary)
                    .contentTransition(.numericText())
                Text(label).font(DS.Font.caption).foregroundStyle(DS.Palette.tertiary)
            }
        }
    }
}

// MARK: - Estante (arquivos e prints)

final class Shelf: ObservableObject {
    static let shared = Shelf()
    @Published private(set) var items: [URL] = []
    @Published var thumbs: [URL: NSImage] = [:]
    private let key = "shelfItems"
    private var folderSource: DispatchSourceFileSystemObject?
    private var folderFD: Int32 = -1
    private var known: Set<String> = []
    private var watchedFolder: URL?

    init() {
        items = (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
        // (não confere se existem aqui: olhar arquivos da Mesa pode pedir permissão e travar a ilha)
    }

    /// Pasta dos prints: a que você escolheu, senão a que o macOS já usa (sem mudar nada no seu Mac).
    static var screenshotFolder: URL {
        if let p = UserDefaults.standard.string(forKey: "shelfFolder"), !p.isEmpty { return URL(fileURLWithPath: p) }
        if let sys = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !sys.isEmpty {
            return URL(fileURLWithPath: (sys as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    func add(_ urls: [URL]) {
        var list = items
        for u in urls where !list.contains(u) { list.insert(u, at: 0) }
        set(Array(list.prefix(30)))
        urls.forEach(thumb)
    }
    func remove(_ u: URL) { set(items.filter { $0 != u }) }
    func clear() { set([]) }
    private func set(_ l: [URL]) {
        withAnimation(DS.Motion.swap) { items = l }
        UserDefaults.standard.set(l.map(\.path), forKey: key)
    }

    func thumb(_ u: URL) {
        guard thumbs[u] == nil else { return }
        thumbs[u] = NSWorkspace.shared.icon(forFile: u.path)
        let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 96, height: 96),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbs[u] = img }
        }
    }

    // Prints novos entram sozinhos na estante
    func watchScreenshots() {
        stopWatching()
        guard Features.shelf, UserDefaults.standard.object(forKey: "shelfScreenshots") as? Bool ?? true else { return }
        let folder = Self.screenshotFolder
        watchedFolder = folder
        // Fora da linha principal: o pedido de permissão da pasta (Mesa) bloqueia quem pergunta
        // até você responder. Na linha principal isso congelava a ilha inteira.
        fileQueue.async { [weak self] in
            let list = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            let fd = open(folder.path, O_EVTONLY)
            DispatchQueue.main.async {
                guard let self, self.watchedFolder == folder, fd >= 0 else { if fd >= 0 { close(fd) }; return }
                self.known = list
                self.folderFD = fd
                let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: self.fileQueue)
                src.setEventHandler { [weak self] in self?.folderChanged() }
                src.setCancelHandler { close(fd) }
                src.resume()
                self.folderSource = src
            }
        }
    }
    private let fileQueue = DispatchQueue(label: "ohmynotch.shelf.files", qos: .utility)
    private func stopWatching() { folderSource?.cancel(); folderSource = nil; folderFD = -1; watchedFolder = nil }

    /// Roda na fila de arquivos; só a parte visual volta para a linha principal.
    private func folderChanged() {
        guard let folder = DispatchQueue.main.sync(execute: { watchedFolder }) else { return }
        let now = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let new = DispatchQueue.main.sync { () -> Set<String> in let n = now.subtracting(known); known = now; return n }
        for name in new where !name.hasPrefix(".") {
            let u = folder.appendingPathComponent(name)
            guard let type = UTType(filenameExtension: u.pathExtension),
                  type.conforms(to: .image) || type.conforms(to: .movie) else { continue }
            // só arquivos recém-criados (não os que você só moveu para lá)
            let created = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            guard Date().timeIntervalSince(created) < 20 else { continue }
            // o macOS escreve o print aos poucos: espera assentar
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, FileManager.default.fileExists(atPath: u.path) else { return }
                self.add([u])
                self.thumbs[u] = nil; self.thumb(u)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    IslandController.shared.showAlert(IslandAlert(
                        symbol: "camera.viewfinder", color: .blue, title: L("Print na estante"),
                        subtitle: L("Arraste da ilha para onde quiser"), image: self.thumbs[u],
                        action: { IslandController.shared.openTab(.shelf) }), duration: 3.5)
                }
            }
        }
    }
}

struct ShelfView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var shelf = Shelf.shared
    var body: some View {
        TabPanel {
            if shelf.items.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: model.dropTargeted ? "tray.and.arrow.down.fill" : "tray")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(model.dropTargeted ? Color.blue : DS.Palette.secondary)
                        .symbolEffect(.bounce, value: model.dropTargeted)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Arraste arquivos até o notch")).font(DS.Font.headline).foregroundStyle(DS.Palette.primary)
                        Text(L("Seus prints também aparecem aqui")).font(DS.Font.body).foregroundStyle(DS.Palette.secondary)
                    }
                    Spacer()
                }
            } else {
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(shelf.items, id: \.self) { u in ShelfTile(url: u) }
                        }
                    }
                    VStack(spacing: 2) {
                        IconButton(symbol: "trash", size: 11, help: L("Limpar a estante")) { shelf.clear() }
                        IconButton(symbol: "folder", size: 11, help: L("Abrir a pasta dos prints")) {
                            NSWorkspace.shared.open(Shelf.screenshotFolder)
                        }
                    }
                }
            }
        }
        .onAppear { shelf.items.forEach(shelf.thumb) }
    }
}

struct ShelfTile: View {
    let url: URL
    @ObservedObject var shelf = Shelf.shared
    @State private var hover = false
    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = shelf.thumbs[url] { Image(nsImage: img).resizable().scaledToFit() }
                    else { Color.white.opacity(0.08) }
                }
                .frame(width: 44, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                if hover {
                    Button { shelf.remove(url) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                            .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.8))
                    }
                    .buttonStyle(.plain).offset(x: 4, y: -4)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            Text(url.lastPathComponent).font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(DS.Palette.secondary).lineLimit(1).truncationMode(.middle)
                .frame(width: 52)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? DS.Palette.hover : .clear))
        .onHover { h in withAnimation(DS.Motion.hover) { hover = h } }
        .onDrag {
            IslandController.shared.beginShelfDrag()
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .help(url.lastPathComponent)
    }
}

// MARK: - Aviso genérico (timer acabou, print salvo, bateria fraca, notificação)

struct IslandAlert {
    var symbol: String
    var color: Color
    var title: String
    var subtitle: String
    var image: NSImage? = nil
    var appName: String? = nil
    var action: (() -> Void)? = nil
}

struct AlertContent: View {
    @ObservedObject var model: IslandModel
    @State private var pop = 0
    var body: some View {
        if let a = model.alert {
            HStack(spacing: 12) {
                Group {
                    if let img = a.image {
                        Image(nsImage: img).resizable().scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    } else {
                        Image(systemName: a.symbol).font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(a.color)
                            .symbolEffect(.bounce, value: pop)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(a.color.opacity(0.16)))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let app = a.appName {
                        Text(app.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Palette.tertiary)
                    }
                    Text(a.title).font(DS.Font.headline).foregroundStyle(DS.Palette.primary).lineLimit(1)
                    if !a.subtitle.isEmpty {
                        Text(a.subtitle).font(DS.Font.body).foregroundStyle(DS.Palette.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .onAppear { pop += 1 }
        }
    }
}

// MARK: - Notificações estilo iPhone (lidas pela Acessibilidade, sem acesso total ao disco)

final class NotificationMirror {
    static let shared = NotificationMirror()
    private var observer: AXObserver?
    private var pid: pid_t = 0
    private var seen: [String: Date] = [:]
    private var launchObs: Any?

    func start() {
        stop()
        guard Features.notifications, AXIsProcessTrusted() else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            return
        }
        pid = app.processIdentifier
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, _, ref in
            guard let ref else { return }
            let me = Unmanaged<NotificationMirror>.fromOpaque(ref).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { me.scan(element) }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let root = AXUIElementCreateApplication(pid)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(obs, root, n as CFString, ref)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        // o processo das notificações pode reiniciar: liga de novo
        launchObs = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if a?.bundleIdentifier == "com.apple.notificationcenterui" { self?.start() }
        }
    }

    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        if let launchObs { NSWorkspace.shared.notificationCenter.removeObserver(launchObs) }
        launchObs = nil
    }

    private func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    private func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    /// Procura balões de notificação (subrole AXNotificationCenterBanner) e lê os textos.
    private func scan(_ start: AXUIElement) {
        let root = AXUIElementCreateApplication(pid)
        var stack = [root], banners: [AXUIElement] = [], visited = 0
        while let e = stack.popLast(), visited < 400 {
            visited += 1
            let sub = attr(e, kAXSubroleAttribute) as? String ?? ""
            if sub.contains("NotificationCenterBanner") || sub.contains("NotificationCenterAlert") { banners.append(e); continue }
            stack.append(contentsOf: children(e))
        }
        for b in banners { read(b) }
    }

    private func read(_ banner: AXUIElement) {
        var texts: [String] = []
        var stack = [banner], n = 0
        while let e = stack.popLast(), n < 60 {
            n += 1
            if (attr(e, kAXRoleAttribute) as? String) == kAXStaticTextRole, let v = attr(e, kAXValueAttribute) as? String,
               !v.trimmingCharacters(in: .whitespaces).isEmpty {
                texts.append(v)
            }
            stack.insert(contentsOf: children(e), at: 0)
        }
        let desc = attr(banner, kAXDescriptionAttribute) as? String ?? ""
        guard !texts.isEmpty || !desc.isEmpty else { return }
        let key = desc + "|" + texts.joined(separator: "|")
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 60 }
        guard seen[key] == nil else { return }
        seen[key] = now

        // Formato comum: [título, (subtítulo), corpo]; o nome do app vem na descrição ("App, Título, Corpo")
        let appName = desc.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        let title = texts.first ?? appName ?? ""
        let body = texts.dropFirst().joined(separator: " · ")
        let icon = appName.flatMap(Self.icon(forAppNamed:))
        IslandController.shared.showAlert(IslandAlert(
            symbol: "bell.fill", color: .red, title: title, subtitle: body, image: icon,
            appName: appName == title ? nil : appName,
            action: { [weak self] in self?.press(banner) }), duration: 5)
    }

    /// Clicar no aviso da ilha = clicar no balão original (abre o app certo).
    private func press(_ banner: AXUIElement) {
        AXUIElementPerformAction(banner, kAXPressAction as CFString)
    }

    static func icon(forAppNamed name: String) -> NSImage? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let i = app.icon { return i }
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
            let p = "\(dir)/\(name).app"
            if FileManager.default.fileExists(atPath: p) { return NSWorkspace.shared.icon(forFile: p) }
        }
        return nil
    }

    /// Para depurar: grava a árvore de Acessibilidade da Central de Notificações.
    func dump() {
        guard pid != 0 || NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first != nil else { return }
        if pid == 0 { pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first!.processIdentifier }
        var out = "trusted=\(AXIsProcessTrusted())\n"
        func walk(_ e: AXUIElement, _ d: Int) {
            guard d < 14 else { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? "?"
            let sub = attr(e, kAXSubroleAttribute) as? String ?? ""
            let val = (attr(e, kAXValueAttribute) as? String) ?? ""
            let desc = (attr(e, kAXDescriptionAttribute) as? String) ?? ""
            var names: CFArray?
            AXUIElementCopyActionNames(e, &names)
            out += String(repeating: "  ", count: d) + "\(role) [\(sub)] v=\(val.prefix(60)) d=\(desc.prefix(80)) a=\((names as? [String]) ?? [])\n"
            children(e).forEach { walk($0, d + 1) }
        }
        walk(AXUIElementCreateApplication(pid), 0)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ohmynotch/ax-notifications.txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }
}
