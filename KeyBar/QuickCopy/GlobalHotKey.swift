import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (⌥⌘K) that opens quick copy from any app.
/// Uses Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    static let displayName = "⌥⌘K"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private let isEnabled: () -> Bool

    init(isEnabled: @escaping () -> Bool, action: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.action = action
    }

    /// Registers or unregisters to match the setting. Returns false if the
    /// shortcut is wanted but another app already owns it.
    @discardableResult
    func update() -> Bool {
        unregister()
        return isEnabled() ? register() : true
    }

    private func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers hot key events on the main thread
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, userData, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x4B59_4252), id: 1)   // 'KYBR'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { unregister() }
        return status == noErr
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}
