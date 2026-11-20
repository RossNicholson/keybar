import AppKit
import ApplicationServices

/// Whether macOS lets KeyBar use Accessibility, which filling passwords needs
enum AccessibilityAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "KeyBar would like to control this computer" prompt,
    /// which leads to System Settings, unless it's allowed already
    @discardableResult
    static func ask() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A password field found on a login page, ready to fill once the user says
/// yes. Holds the field and the frames around it, so the page can be checked
/// again just before typing.
struct FillTarget: @unchecked Sendable {
    let browser: String
    let pid: pid_t
    let host: String
    fileprivate let field: AXUIElement
    fileprivate let window: AXUIElement
    /// The web areas from the page down to the field's own frame
    fileprivate let frames: [AXUIElement]
    /// A Chromium browser KeyBar turned Accessibility on in, to turn off again
    fileprivate let restore: AXUIElement?
}

/// Fills a stored password into the login page open in a browser, through
/// Accessibility: finds the password field on a page that's on one of the
/// password's websites, and types the password into it, checking the page
/// again first. Needs no browser extension. Runs off the main thread (every
/// call waits on the browser). The value is only ever given to the field.
final class LoginFiller: @unchecked Sendable {
    /// The most elements looked at in one window, and how deep: enough for
    /// any login page, without hanging on a huge one
    private static let maxElements = 40_000
    private static let maxDepth = 120
    /// How long typing the last character takes to reach the page
    private static let settle: useconds_t = 150_000
    /// The longest to wait for a Chromium browser's pages to appear
    private static let chromiumWarmUp: TimeInterval = 5

    init() {
        // A browser that's stopped answering mustn't hold up the bridge
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)
    }

    // MARK: - Finding the field

    /// The password field to fill for these websites (and `site`, when given:
    /// only pages on it). Focuses a lone unfocused field.
    func locate(websites: [String], site: String? = nil) -> Result<FillTarget, FillProblem> {
        guard AccessibilityAccess.isTrusted else { return .failure(.notTrusted) }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var found: [(candidate: FillCandidate, field: AXUIElement, window: AXUIElement, frames: [AXUIElement],
                     pid: pid_t, restore: AXUIElement?)] = []
        var pages: [(host: String, browser: String)] = []
        var anyBrowser = false
        var turnedOn: [AXUIElement] = []

        for browser in FillBrowser.all {
            for bundleID in browser.bundleIDs {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where !app.isTerminated {
                    anyBrowser = true
                    let pid = app.processIdentifier
                    let appElement = AXUIElementCreateApplication(pid)
                    var restore: AXUIElement?
                    if browser.chromium, Self.turnOnWebAccessibility(appElement) {
                        restore = appElement
                        turnedOn.append(appElement)
                    }
                    var scan = scanApp(appElement, websites: websites, site: site)
                    // Chromium builds its pages' tree a moment after being
                    // asked (about 2 seconds for Chrome)
                    if restore != nil {
                        let deadline = Date().addingTimeInterval(Self.chromiumWarmUp)
                        while !scan.sawPage && Date() < deadline {
                            usleep(200_000)
                            scan = scanApp(appElement, websites: websites, site: site)
                        }
                    }
                    pages += scan.pages.map { ($0, browser.name) }
                    for field in scan.fields {
                        let candidate = FillCandidate(browser: browser.name, host: field.host, focused: field.focused,
                                                      inMainWindow: field.inMainWindow, inFrontApp: pid == front)
                        found.append((candidate, field.element, field.window, field.frames, pid, restore))
                    }
                }
            }
        }

        func fail(_ problem: FillProblem) -> Result<FillTarget, FillProblem> {
            turnedOn.forEach(Self.turnOffWebAccessibility)
            return .failure(problem)
        }
        guard anyBrowser else { return fail(.noBrowser) }

        switch FillChoice.choose(found.map(\.candidate)) {
        case .none:
            if let page = pages.first { return fail(.noField(host: page.host, browser: page.browser)) }
            return fail(.noPage(site.map { [$0] } ?? websites))
        case .several(let count):
            return fail(.several(count))
        case .fill(let index, let needsFocus):
            let chosen = found[index]
            let host = chosen.candidate.host, browserName = chosen.candidate.browser
            // Typing goes to the browser's main window
            if !Self.bool(chosen.window, kAXMainAttribute) {
                AXUIElementSetAttributeValue(chosen.window, kAXMainAttribute as CFString, kCFBooleanTrue)
                guard Self.bool(chosen.window, kAXMainAttribute) else {
                    return fail(.notFrontWindow(host: host, browser: browserName))
                }
            }
            if needsFocus {
                AXUIElementSetAttributeValue(chosen.field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                usleep(100_000)
            }
            guard Self.isFocused(chosen.field, pid: chosen.pid) else {
                return fail(.couldNotFocus(host: host, browser: browserName))
            }
            // Leave Accessibility on only where the fill still needs it
            // (CFEqual traps on nil: a Safari fill with Chrome open has none)
            turnedOn.filter { other in chosen.restore.map { !CFEqual(other, $0) } ?? true }
                .forEach(Self.turnOffWebAccessibility)
            return .success(FillTarget(browser: browserName, pid: chosen.pid, host: host, field: chosen.field,
                                       window: chosen.window, frames: chosen.frames, restore: chosen.restore))
        }
    }

    private struct FoundField {
        var element: AXUIElement
        var window: AXUIElement
        var frames: [AXUIElement]
        var host: String
        var focused: Bool
        var inMainWindow: Bool
    }

    /// The fillable password fields in one browser, and the hosts of the
    /// pages it has open on the websites (with or without a field). `sawPage`:
    /// it showed any web page at all.
    private func scanApp(_ app: AXUIElement, websites: [String], site: String?) -> (fields: [FoundField], pages: [String], sawPage: Bool) {
        let focusedElement = Self.element(app, kAXFocusedUIElementAttribute)
        var fields: [FoundField] = []
        var pages: [String] = []
        var sawPage = false
        for window in Self.elements(app, kAXWindowsAttribute) where !Self.bool(window, kAXMinimizedAttribute) {
            let isMain = Self.bool(window, kAXMainAttribute)
            var visited = 0
            // Depth first, carrying the web areas (frames) above each element
            var stack: [(element: AXUIElement, frames: [AXUIElement], urls: [URL?], depth: Int)] = [(window, [], [], 0)]
            while let (element, framesAbove, urlsAbove, depth) = stack.popLast() {
                visited += 1
                guard visited <= Self.maxElements else { break }
                let values = Self.attributes(element, [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute])
                let role = values[0] as? String
                let subrole = values[1] as? String
                var frames = framesAbove, urls = urlsAbove
                if role == "AXWebArea" {
                    sawPage = true
                    frames.append(element)
                    urls.append(Self.url(element))
                    if let host = allowedHost(urls, websites: websites, site: site), !pages.contains(host) { pages.append(host) }
                }
                if subrole == kAXSecureTextFieldSubrole as String {
                    if !frames.isEmpty, let host = allowedHost(urls, websites: websites, site: site) {
                        let focused = focusedElement.map { CFEqual($0, element) } ?? false || Self.bool(element, kAXFocusedAttribute)
                        fields.append(FoundField(element: element, window: window, frames: frames, host: host,
                                                 focused: focused, inMainWindow: isMain))
                    }
                    continue
                }
                guard depth < Self.maxDepth, let children = values[2] as? [AXUIElement] else { continue }
                for child in children.reversed() { stack.append((child, frames, urls, depth + 1)) }
            }
        }
        return (fields, pages, sawPage)
    }

    private func allowedHost(_ urls: [URL?], websites: [String], site: String?) -> String? {
        guard let host = LoginSite.allowedHost(frames: urls, websites: websites) else { return nil }
        if let site, !LoginSite.matches(host, websites: [site]) { return nil }
        return host
    }

    // MARK: - Filling

    /// Types the password into the field, after checking the page is still
    /// on the websites and the field still has the focus in the front window.
    /// Afterwards the field must hold the whole password, or it's cleared.
    func fill(_ target: FillTarget, password: String, websites: [String]) -> Result<Void, FillProblem> {
        defer { finish(target) }
        guard AccessibilityAccess.isTrusted else { return .failure(.notTrusted) }
        guard let (head, last) = FillTyping.split(password) else { return .failure(.failed("the password is empty.")) }
        let host = target.host, browser = target.browser

        // Still the same, allowed page: the user may have moved on while
        // Touch ID asked
        let urls = target.frames.map(Self.url)
        guard let now = LoginSite.allowedHost(frames: urls, websites: websites), now == host,
              Self.bool(target.window, kAXMainAttribute), Self.isFocused(target.field, pid: target.pid) else {
            return .failure(.pageChanged(host: host, browser: browser))
        }

        let set = AXUIElementSetAttributeValue(target.field, kAXValueAttribute as CFString, head as CFString)
        guard set == .success else { return .failure(.failed("the password field can't be changed (error \(set.rawValue)).")) }
        // The key press lands after what's there
        var range = CFRange(location: head.utf16.count, length: 0)
        if let value = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(target.field, kAXSelectedTextRangeAttribute as CFString, value)
        }
        guard Self.type(last, to: target.pid) else {
            clear(target)
            return .failure(.failed("macOS didn't let KeyBar type into the browser."))
        }
        usleep(Self.settle)
        let count = (Self.value(target.field, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue ?? -1
        guard FillTyping.holdsWhole(count, of: password) else {
            clear(target)
            return .failure(.notTaken(host: host, browser: browser))
        }
        return .success(())
    }

    /// Turns Accessibility back off in a Chromium browser KeyBar turned it on
    /// in. Safe to call more than once.
    func finish(_ target: FillTarget) {
        if let restore = target.restore { Self.turnOffWebAccessibility(restore) }
    }

    private func clear(_ target: FillTarget) {
        AXUIElementSetAttributeValue(target.field, kAXValueAttribute as CFString, "" as CFString)
    }

    /// A key down and up carrying `text`, sent to the browser's process. A
    /// trusted event: the page gets keydown, beforeinput and input, even with
    /// the window in the background.
    private static func type(_ text: String, to pid: pid_t) -> Bool {
        var units = Array(text.utf16)
        // CGEvent carries at most 20 UTF-16 units; one character is far fewer
        guard !units.isEmpty, units.count <= 20 else { return false }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return false }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.postToPid(pid)
        }
        return true
    }

    // MARK: - Chromium

    /// Chromium only builds its web pages' Accessibility tree when asked.
    /// Returns true if KeyBar turned it on (so should turn it off after).
    /// Chrome answers "not implemented" to AXEnhancedUserInterface yet does
    /// it, so what counts is reading it back.
    private static func turnOnWebAccessibility(_ app: AXUIElement) -> Bool {
        if bool(app, "AXManualAccessibility") || bool(app, "AXEnhancedUserInterface") { return false }
        for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
            if bool(app, attribute) { return true }
        }
        return false
    }

    private static func turnOffWebAccessibility(_ app: AXUIElement) {
        if bool(app, "AXManualAccessibility") {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
        }
        if bool(app, "AXEnhancedUserInterface") {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
    }

    // MARK: - Accessibility plumbing

    /// Has the keyboard focus: the field says so, or it's its app's focused element
    private static func isFocused(_ field: AXUIElement, pid: pid_t) -> Bool {
        if bool(field, kAXFocusedAttribute) { return true }
        guard let focused = element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused, field)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    /// Several attributes in one round trip; NSNull for any it hasn't got
    private static func attributes(_ element: AXUIElement, _ names: [String]) -> [AnyObject?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
              let array = values as? [AnyObject], array.count == names.count else {
            return names.map { value(element, $0) }
        }
        return array.map { $0 is NSNull || CFGetTypeID($0) == AXValueGetTypeID() && AXValueGetType($0 as! AXValue) == .axError ? nil : $0 }
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        (value(element, attribute) as? Bool) ?? false
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (value(element, attribute) as? [AXUIElement]) ?? []
    }

    private static func url(_ element: AXUIElement) -> URL? {
        let value = value(element, "AXURL")
        if let url = value as? URL { return url }
        if let text = value as? String { return URL(string: text) }
        return nil
    }
}
