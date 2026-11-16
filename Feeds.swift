// Música tocando (Spotify e Música) e eventos do calendário.

import AppKit
import EventKit
import SwiftUI

// MARK: - Música

final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    @Published var title = ""
    @Published var artist = ""
    @Published var isPlaying = false
    @Published var artwork: NSImage?
    @Published var app: String?          // "Spotify" ou "Music"
    @Published var accent: Color = .green   // cor tirada da capa do álbum

    var hasTrack: Bool { !title.isEmpty }

    // Para a música expandida
    @Published var position: Double = 0       // segundos
    @Published var duration: Double = 0       // segundos
    @Published var upNext: [String] = []      // próximas faixas (app Música; o Spotify não expõe a fila)
    private var detailTimer: Timer?

    var bundleID: String? { universalBundle ?? app.flatMap { bundleIDs[$0] } }

    // Música de QUALQUER app (navegador, YouTube, Podcasts...) via adaptador MediaRemote, se estiver instalado
    @Published private(set) var universal = false
    private var universalBundle: String?
    private var uElapsed: Double = 0, uStamp = Date(), uState: [String: Any] = [:]

    /// Liga/desliga a atualização de tempo e fila (só enquanto a música expandida está aberta).
    func setDetailed(_ on: Bool) {
        detailTimer?.invalidate(); detailTimer = nil
        guard on else { return }
        refreshDetails()
        detailTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshDetails(queue: false) }
    }

    func refreshDetails(queue: Bool = true) {
        if universal {
            position = min(duration > 0 ? duration : .infinity, uElapsed + (isPlaying ? Date().timeIntervalSince(uStamp) : 0))
            guard universalBundle == "com.apple.Music", queue else { if universalBundle != "com.apple.Music" { upNext = [] }; return }
        }
        guard let app, isRunning(app) else { return }
        let durScale = app == "Spotify" ? 1000.0 : 1.0
        let src = "tell application \"\(app)\" to return {player position, duration of current track}"
        let qsrc = """
        tell application "Music"
            set out to {}
            try
                set pl to current playlist
                set idx to index of current track
                set n to count of tracks of pl
                set lastI to idx + 6
                if lastI > n then set lastI to n
                repeat with i from (idx + 1) to lastI
                    set t to track i of pl
                    set end of out to ((name of t) & " — " & (artist of t))
                end repeat
            end try
            return out
        end tell
        """
        self.queue_ = queue && app == "Music"
        self.queue.async { [weak self] in
            var pos = 0.0, dur = 0.0
            if let r = Self.run(src), r.numberOfItems >= 2 {
                pos = r.atIndex(1)?.doubleValue ?? 0
                dur = (r.atIndex(2)?.doubleValue ?? 0) / durScale
            }
            var next: [String]? = nil
            if self?.queue_ == true, let q = Self.run(qsrc) {
                next = (0..<q.numberOfItems).compactMap { q.atIndex($0 + 1)?.stringValue }
            }
            DispatchQueue.main.async {
                self?.position = pos; self?.duration = dur
                if let next { self?.upNext = next } else if app != "Music" { self?.upNext = [] }
            }
        }
    }
    private var queue_ = false

    /// Toca a n-ésima próxima faixa da fila (app Música).
    func playUpNext(_ offset: Int) {
        guard app == "Music" else { return }
        queue.async { [weak self] in
            _ = Self.run("""
            tell application "Music"
                set pl to current playlist
                play track ((index of current track) + \(offset + 1)) of pl
            end tell
            """)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refreshDetails() }
        }
    }

    func seek(to fraction: Double) {
        if universal, duration > 0 {
            let t = max(0, min(duration, duration * fraction))
            position = t; uElapsed = t; uStamp = Date()
            UniversalMedia.shared.seek(t); return
        }
        guard let app, duration > 0 else { return }
        let t = max(0, min(duration, duration * fraction))
        position = t
        queue.async { _ = Self.run("tell application \"\(app)\" to set player position to \(t)") }
    }

    func openPlayingApp() {
        guard let id = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private let queue = DispatchQueue(label: "volumeseguro.music")
    private var artKey = ""
    private let bundleIDs = ["Spotify": "com.spotify.client", "Music": "com.apple.Music"]

    func start() {
        // prefere o adaptador universal; se não existir ou falhar, usa Spotify/Música por AppleScript
        if UniversalMedia.shared.available && Features.music {
            UniversalMedia.shared.start { [weak self] p, diff in self?.applyUniversal(p, diff: diff) }
                onFail: { [weak self] in self?.universal = false; self?.refresh() }
            universal = true
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            self?.handle(n.userInfo, app: "Spotify")
        }
        dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            self?.handle(n.userInfo, app: "Music")
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            guard let self, let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let app = self.app, a.bundleIdentifier == self.bundleIDs[app] else { return }
            self.clear()
        }
        refresh()
    }

    private func isRunning(_ app: String) -> Bool {
        guard let id = bundleIDs[app] else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    /// Recurso Música ligado/desligado nos Ajustes.
    func featureChanged() { if Features.music { refresh() } else { clear() } }

    private func clear() {
        title = ""; artist = ""; isPlaying = false; artwork = nil; app = nil; artKey = ""
    }

    private func handle(_ info: [AnyHashable: Any]?, app: String) {
        guard let info, Features.music, !universal else { return }
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" {
            if self.app == app || self.app == nil { clear() }
            return
        }
        // um app pausado não toma o lugar de outro que está tocando
        if state != "Playing", let cur = self.app, cur != app, isPlaying { return }
        self.app = app
        title = info["Name"] as? String ?? title
        artist = info["Artist"] as? String ?? ""
        isPlaying = state == "Playing"
        fetchArtwork()
    }

    /// Estado inicial (ao abrir o app), só para apps já abertos (não abre o Spotify sozinho).
    private func refresh() {
        guard Features.music, !universal else { return }
        for app in ["Spotify", "Music"] where isRunning(app) {
            let src = "tell application \"\(app)\" to return {player state as string, name of current track, artist of current track}"
            queue.async { [weak self] in
                guard let r = Self.run(src), r.numberOfItems >= 3 else { return }
                let state = r.atIndex(1)?.stringValue ?? ""
                let name = r.atIndex(2)?.stringValue ?? ""
                let artist = r.atIndex(3)?.stringValue ?? ""
                DispatchQueue.main.async {
                    guard let self, state == "playing" || state == "paused", !name.isEmpty else { return }
                    if self.isPlaying && state != "playing" { return }
                    self.app = app; self.title = name; self.artist = artist
                    self.isPlaying = state == "playing"
                    self.fetchArtwork()
                }
            }
        }
    }

    private func fetchArtwork() {
        guard let app else { return }
        let key = app + title + artist
        guard key != artKey else { return }
        artKey = key
        artwork = nil
        queue.async { [weak self] in
            var img: NSImage?
            if app == "Spotify" {
                if let s = Self.run("tell application \"Spotify\" to return artwork url of current track")?.stringValue,
                   let url = URL(string: s), let data = try? Data(contentsOf: url) {
                    img = NSImage(data: data)
                }
            } else if let d = Self.run("tell application \"Music\" to return data of artwork 1 of current track")?.data {
                img = NSImage(data: d)
            }
            let c = img.flatMap(Self.vividColor)
            DispatchQueue.main.async {
                guard self?.artKey == key else { return }
                self?.artwork = img
                withAnimation(.easeInOut(duration: 0.5)) { self?.accent = c ?? .green }
            }
        }
    }

    /// Cor média da capa, mais viva e clara para aparecer no fundo preto.
    static func vividColor(_ img: NSImage) -> Color? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let ns = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.15 { return Color(white: 0.85) }   // capa sem cor: equalizador claro
        return Color(hue: h, saturation: min(1, max(0.55, s * 1.3)), brightness: max(0.85, b))
    }

    func playPause() {
        if universal { UniversalMedia.shared.send(2); isPlaying.toggle(); return }
        command("playpause"); isPlaying.toggle()
    }
    func next() { universal ? UniversalMedia.shared.send(4) : command("next track") }
    func previous() { universal ? UniversalMedia.shared.send(5) : command("previous track") }

    /// Atualização vinda do adaptador universal (JSON do MediaRemote).
    private func applyUniversal(_ p: [String: Any], diff: Bool) {
        guard Features.music else { return }
        if diff { for (k, v) in p { if v is NSNull { uState[k] = nil } else { uState[k] = v } } } else { uState = p }
        let s = uState
        let newTitle = s["title"] as? String ?? ""
        guard !newTitle.isEmpty else { clear(); universalBundle = nil; return }
        let bundle = (s["parentApplicationBundleIdentifier"] as? String) ?? (s["bundleIdentifier"] as? String)
        universalBundle = bundle
        app = bundle == "com.spotify.client" ? "Spotify" : (bundle == "com.apple.Music" ? "Music" :
              bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                    .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") })
        let trackChanged = newTitle != title
        title = newTitle
        artist = s["artist"] as? String ?? (s["album"] as? String ?? "")
        isPlaying = s["playing"] as? Bool ?? false
        duration = s["duration"] as? Double ?? 0
        uElapsed = s["elapsedTime"] as? Double ?? 0
        if let ts = s["timestamp"] as? String, let d = ISO8601DateFormatter.flexible.date(from: ts) { uStamp = d }
        else if let ts = s["timestamp"] as? Double { uStamp = Date(timeIntervalSince1970: ts > 1e11 ? ts / 1000 : ts) }
        else { uStamp = Date() }
        position = uElapsed + (isPlaying ? Date().timeIntervalSince(uStamp) : 0)
        if p["artworkData"] != nil || trackChanged {
            if let b64 = s["artworkData"] as? String, let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
                artwork = img
                let c = Self.vividColor(img)
                withAnimation(.easeInOut(duration: 0.5)) { accent = c ?? .green }
            } else if trackChanged {
                artwork = bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
            }
        }
        artKey = (app ?? "") + title + artist
    }

    private func command(_ c: String) {
        guard let app, isRunning(app) else { return }
        queue.async { _ = Self.run("tell application \"\(app)\" to \(c)") }
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil ? r : nil
    }
}

// MARK: - Adaptador universal (MediaRemote via /usr/bin/perl, projeto aberto mediaremote-adapter, BSD-3)
// Só é usado se o framework do adaptador estiver dentro do app (veja setup-musica-universal.sh).

final class UniversalMedia {
    static let shared = UniversalMedia()
    private var process: Process?
    private var buffer = Data()
    private var failures = 0
    private var onUpdate: (([String: Any], Bool) -> Void)?
    private var onFail: (() -> Void)?
    private var stopping = false

    private var script: String? { Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl") }
    private var framework: String? { Bundle.main.path(forResource: "MediaRemoteAdapter", ofType: "framework") }
    var available: Bool {
        guard UserDefaults.standard.object(forKey: "universalMusic") as? Bool ?? true else { return false }
        return script != nil && framework != nil
    }

    func start(onUpdate: @escaping ([String: Any], Bool) -> Void, onFail: @escaping () -> Void) {
        self.onUpdate = onUpdate; self.onFail = onFail
        launch()
    }

    private func launch() {
        guard let script, let framework else { return }
        // um adaptador órfão de uma execução anterior (app fechado à força) não pode ficar rodando
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-f", script]
        try? k.run(); k.waitUntilExit()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework, "stream", "--debounce=80"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(d) }
        }
        let startedAt = Date()
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                out.fileHandleForReading.readabilityHandler = nil
                // morreu logo de cara várias vezes: o adaptador não funciona neste macOS, volta ao AppleScript
                if Date().timeIntervalSince(startedAt) < 5 { self.failures += 1 } else { self.failures = 0 }
                if self.failures >= 3 { self.onFail?(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.launch() }
            }
        }
        do { try p.run(); process = p } catch { onFail?() }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            onUpdate?(payload, obj["diff"] as? Bool ?? false)
        }
    }

    private func run(_ args: [String]) {
        guard let script, let framework else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }
    func send(_ command: Int) { run(["send", String(command)]) }
    func seek(_ seconds: Double) { run(["seek", String(Int(seconds * 1_000_000))]) }

    func stop() { stopping = true; process?.terminate(); process = nil }
}

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}

// MARK: - Calendário

final class CalendarFeed: ObservableObject {
    static let shared = CalendarFeed()

    struct Item: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: Color
    }

    @Published var items: [Item] = []
    @Published var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let store = EKEventStore()
    private var started = false

    var authorized: Bool { access == .fullAccess }

    /// Chamado na primeira vez que a ilha abre (pede permissão só quando faz sentido).
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.load()
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.load() }
        if access == .notDetermined { request() } else { load() }
    }

    func request() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.access = EKEventStore.authorizationStatus(for: .event)
                self?.load()
            }
        }
    }

    func load() {
        access = EKEventStore.authorizationStatus(for: .event)
        guard authorized else { items = []; return }
        let now = Date()
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        let pred = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        items = store.events(matching: pred)
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .prefix(3)
            .map { e in
                Item(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Evento",
                     start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                     color: Color(nsColor: e.calendar?.color ?? .systemBlue))
            }
    }
}
