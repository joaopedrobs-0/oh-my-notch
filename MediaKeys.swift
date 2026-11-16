// Teclas de volume, mudo e brilho: o app aplica a mudança e mostra só o aviso do notch,
// sem o aviso padrão do macOS. Mesma técnica do MewNotch/Eyelid: um "event tap" que
// intercepta as teclas de mídia (precisa da permissão de Acessibilidade).
// Sem a permissão, nada muda: as teclas seguem para o macOS normalmente.

import AppKit
import CoreAudio
import ApplicationServices

final class MediaKeys {
    static let shared = MediaKeys()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?

    // códigos das teclas de mídia (NX_KEYTYPE_*)
    private enum Key: Int { case soundUp = 0, soundDown = 1, brightUp = 2, brightDown = 3, mute = 7 }

    var enabled: Bool { UserDefaults.standard.object(forKey: "replaceSystemHUD") as? Bool ?? true }
    var active: Bool { tap != nil }

    /// Liga se tiver permissão; se não, pede (uma vez) e tenta de novo a cada poucos segundos.
    func start(prompt: Bool = false) {
        guard enabled, tap == nil else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                if AXIsProcessTrusted() {
                    self?.retryTimer?.invalidate(); self?.start()
                    NotificationMirror.shared.start()
                }
            }
            return
        }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, ref in
            let me = Unmanaged<MediaKeys>.fromOpaque(ref!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    /// Abre o pedido de Acessibilidade do macOS (uma vez) e liga tudo que depende dela quando for permitido.
    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) { start(); NotificationMirror.shared.start(); return }
        start(prompt: false)
    }

    func stop() {
        retryTimer?.invalidate()
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // o macOS desliga o tap se ele demorar; religa
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data = ns.data1
        let code = (data & 0xFFFF0000) >> 16
        let state = (data & 0xFF00) >> 8          // 0xA = pressionou, 0xB = soltou
        guard let key = Key(rawValue: code), Features.hud else { return Unmanaged.passUnretained(event) }
        // brilho só se conseguirmos controlar a tela; senão deixa o macOS cuidar
        if (key == .brightUp || key == .brightDown) && !BrightnessMonitor.shared.canSet {
            return Unmanaged.passUnretained(event)
        }
        if state == 0xA {
            let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
            let step: Float = fine ? 1.0 / 64 : 1.0 / 16
            DispatchQueue.main.async {
                switch key {
                case .soundUp: AudioMonitor.shared.stepVolume(+step)
                case .soundDown: AudioMonitor.shared.stepVolume(-step)
                case .mute: AudioMonitor.shared.toggleMute()
                case .brightUp: BrightnessMonitor.shared.step(+step)
                case .brightDown: BrightnessMonitor.shared.step(-step)
                }
            }
        }
        return nil   // engole a tecla: o aviso padrão do macOS não aparece
    }
}
