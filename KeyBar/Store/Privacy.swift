import AppKit
import LocalAuthentication

/// Copying a key: it's marked so clipboard managers skip it, and wiped after
/// a while if nothing else has been copied since
@MainActor
enum Clipboard {
    /// nspasteboard.org markers that clipboard managers respect
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func copySecret(_ value: String, clearAfter seconds: TimeInterval) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed, transient], owner: nil)
        pasteboard.setString(value, forType: .string)
        pasteboard.setData(Data(), forType: concealed)
        pasteboard.setData(Data(), forType: transient)
        let count = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            // Only if it's still our copy on the clipboard
            if NSPasteboard.general.changeCount == count {
                NSPasteboard.general.clearContents()
            }
        }
    }

    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Asks for Touch ID (or the Mac's password) before a key is shown or copied
@MainActor
enum OwnerCheck {
    /// Whether the Mac can ask at all. Without Touch ID or a password, keys are just shown.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static func confirm(_ reason: String, required: Bool) async -> Bool {
        guard required else { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
