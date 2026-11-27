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

/// A login form found on a page, ready to fill once the user says yes: the
/// password field (and the username field above it, if there is one), or on
/// the first page of a two-step sign-in, the username field alone. Holds the
/// frames around it, so the page can be checked again just before typing.
struct FillTarget: @unchecked Sendable {
    let browser: String
    let pid: pid_t
    let host: String
    let step: FillStep
    /// The password field, or for a `.username` step the username field
    fileprivate let field: AXUIElement
    /// For a `.login` step: the username field above the password field
    fileprivate let usernameField: AXUIElement?
    fileprivate let window: AXUIElement
    /// The web areas from the page down to the field's own frame
    fileprivate let frames: [AXUIElement]
    /// A Chromium browser KeyBar turned Accessibility on in, to turn off again
    fileprivate let restore: AXUIElement?

    var hasUsernameField: Bool { usernameField != nil }
}

/// Signs in with a stored login on the page open in a browser, through
/// Accessibility: finds the login form on a page that's on one of the
/// login's websites, types the username and password into it (checking the
/// page again first), presses Return, and empties the password box if the
/// page still shows it a few seconds later. Needs no browser extension. Runs
/// off the main thread (every call waits on the browser). The values are only
/// ever given to the fields.
final class LoginFiller: @unchecked Sendable {
    /// The most elements looked at in one window, and how deep: enough for
    /// any login page, without hanging on a huge one
    private static let maxElements = 40_000
    private static let maxDepth = 120
    /// How long typing the last character takes to reach the page
    private static let settle: useconds_t = 150_000
    /// The longest to wait for a Chromium browser's pages to appear
    private static let chromiumWarmUp: TimeInterval = 5
    /// How long after Return the page has to move on before KeyBar empties
    /// the password box
    private static let submitWait: TimeInterval = 6
    /// After sending a username, a moment for the page to react
    private static let usernameWait: useconds_t = 800_000

    init() {
        // A browser that's stopped answering mustn't hold up the bridge
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)
    }

    // MARK: - Finding the fields

    /// The login form to fill for these websites (and `site`, when given:
    /// only pages on it). A page with a password field comes first; a page
    /// with only a username field counts when the login has a username
    /// (`wantsUsername`). Focuses a lone unfocused field.
    func locate(websites: [String], site: String? = nil, wantsUsername: Bool = true) -> Result<FillTarget, FillProblem> {
        guard AccessibilityAccess.isTrusted else { return .failure(.notTrusted) }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        typealias Found = (candidate: FillCandidate, field: FoundField, pid: pid_t, restore: AXUIElement?)
        var passwordFields: [Found] = []
        var usernameFields: [Found] = []
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
                    for field in scan.passwordFields {
                        let candidate = FillCandidate(browser: browser.name, host: field.host, focused: field.focused,
                                                      inMainWindow: field.inMainWindow, inFrontApp: pid == front)
                        passwordFields.append((candidate, field, pid, restore))
                    }
                    for field in scan.usernameFields {
                        let candidate = FillCandidate(browser: browser.name, host: field.host, focused: field.focused,
                                                      inMainWindow: field.inMainWindow, inFrontApp: pid == front)
                        usernameFields.append((candidate, field, pid, restore))
                    }
                }
            }
        }

        func fail(_ problem: FillProblem) -> Result<FillTarget, FillProblem> {
            turnedOn.forEach(Self.turnOffWebAccessibility)
            return .failure(problem)
        }
        guard anyBrowser else { return fail(.noBrowser) }

        // A password field anywhere wins; a username-only page is the first
        // step of a two-step sign-in
        let step: FillStep = passwordFields.isEmpty && wantsUsername && !usernameFields.isEmpty ? .username : .login
        let found = step == .login ? passwordFields : usernameFields
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
            if !Self.bool(chosen.field.window, kAXMainAttribute) {
                AXUIElementSetAttributeValue(chosen.field.window, kAXMainAttribute as CFString, kCFBooleanTrue)
                guard Self.bool(chosen.field.window, kAXMainAttribute) else {
                    return fail(.notFrontWindow(host: host, browser: browserName))
                }
            }
            if needsFocus {
                AXUIElementSetAttributeValue(chosen.field.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                usleep(100_000)
            }
            guard Self.isFocused(chosen.field.element, pid: chosen.pid) else {
                return fail(.couldNotFocus(host: host, browser: browserName))
            }
            // Leave Accessibility on only where the fill still needs it
            // (CFEqual traps on nil: a Safari fill with Chrome open has none)
            turnedOn.filter { other in chosen.restore.map { !CFEqual(other, $0) } ?? true }
                .forEach(Self.turnOffWebAccessibility)
            return .success(FillTarget(browser: browserName, pid: chosen.pid, host: host, step: step,
                                       field: chosen.field.element, usernameField: step == .login ? chosen.field.username : nil,
                                       window: chosen.field.window, frames: chosen.field.frames, restore: chosen.restore))
        }
    }

    private struct FoundField {
        var element: AXUIElement
        /// For a password field: the username field above it, if any
        var username: AXUIElement?
        var window: AXUIElement
        var frames: [AXUIElement]
        var host: String
        var focused: Bool
        var inMainWindow: Bool
    }

    /// One text or password field met on the way through a page, in order
    private struct SeenField {
        var element: AXUIElement
        var secure: Bool
        /// The innermost web area (frame) it's in
        var frame: AXUIElement
        var frames: [AXUIElement]
        /// Its page's host, if that's on the login's websites
        var host: String?
        var focused: Bool
    }

    /// The fillable password fields in one browser (each with the username
    /// field above it in the same frame, if any), the username fields of
    /// allowed pages that have no password field, and the hosts of the pages
    /// it has open on the websites. `sawPage`: it showed any web page at all.
    private func scanApp(_ app: AXUIElement, websites: [String], site: String?)
        -> (passwordFields: [FoundField], usernameFields: [FoundField], pages: [String], sawPage: Bool) {
        let focusedElement = Self.element(app, kAXFocusedUIElementAttribute)
        var passwordFields: [FoundField] = []
        var usernameFields: [FoundField] = []
        var pages: [String] = []
        var sawPage = false
        for window in Self.elements(app, kAXWindowsAttribute) where !Self.bool(window, kAXMinimizedAttribute) {
            let isMain = Self.bool(window, kAXMainAttribute)
            var visited = 0
            var seen: [SeenField] = []
            // Depth first in page order, carrying the web areas (frames) above
            // each element
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
                let secure = subrole == kAXSecureTextFieldSubrole as String
                let text = role == kAXTextFieldRole as String && !secure && subrole != "AXSearchField"
                if secure || text {
                    if let frame = frames.last {
                        let focused = focusedElement.map { CFEqual($0, element) } ?? false || Self.bool(element, kAXFocusedAttribute)
                        seen.append(SeenField(element: element, secure: secure, frame: frame, frames: frames,
                                              host: allowedHost(urls, websites: websites, site: site), focused: focused))
                    }
                    continue
                }
                guard depth < Self.maxDepth, let children = values[2] as? [AXUIElement] else { continue }
                for child in children.reversed() { stack.append((child, frames, urls, depth + 1)) }
            }

            // Each password field on an allowed page, with the nearest text
            // field before it in its frame (no other password field between)
            // as its username field, unless that looks like a search box
            for (index, field) in seen.enumerated() where field.secure {
                guard let host = field.host else { continue }
                var username: AXUIElement?
                for earlier in seen[..<index].reversed() where CFEqual(earlier.frame, field.frame) {
                    if earlier.secure { break }
                    if !Self.looksLikeSearch(earlier.element) { username = earlier.element }
                    break
                }
                passwordFields.append(FoundField(element: field.element, username: username, window: window, frames: field.frames,
                                                 host: host, focused: field.focused, inMainWindow: isMain))
            }
            // Frames on allowed pages with no password field: their text
            // fields could be the username step of a two-step sign-in
            let framesWithPasswords = seen.filter(\.secure).map(\.frame)
            for field in seen where !field.secure {
                guard let host = field.host, !framesWithPasswords.contains(where: { CFEqual($0, field.frame) }),
                      !Self.looksLikeSearch(field.element) else { continue }
                usernameFields.append(FoundField(element: field.element, username: nil, window: window, frames: field.frames,
                                                 host: host, focused: field.focused, inMainWindow: isMain))
            }
        }
        return (passwordFields, usernameFields, pages, sawPage)
    }

    private static func looksLikeSearch(_ field: AXUIElement) -> Bool {
        let values = attributes(field, ["AXDOMIdentifier", "AXDOMClassList", "AXPlaceholderValue", kAXDescriptionAttribute, kAXTitleAttribute])
        var hints: [String] = []
        for value in values {
            if let text = value as? String { hints.append(text) }
            if let list = value as? [String] { hints += list }
        }
        return UsernameField.looksLikeSearch(hints)
    }

    private func allowedHost(_ urls: [URL?], websites: [String], site: String?) -> String? {
        guard let host = LoginSite.allowedHost(frames: urls, websites: websites) else { return nil }
        if let site, !LoginSite.matches(host, websites: [site]) { return nil }
        return host
    }

    // MARK: - Filling

    /// Types the login into the page, after checking the page is still on
    /// the websites and the field still has the focus in the front window:
    /// the username (if there's a field for it and the login has one), then
    /// the password, then Return. Each field must hold exactly what was typed,
    /// or the password box is cleared. If the page still shows the filled
    /// password box a few seconds after Return, it's emptied.
    func fill(_ target: FillTarget, username: String?, password: String, websites: [String]) -> Result<FillOutcome, FillProblem> {
        defer { finish(target) }
        guard AccessibilityAccess.isTrusted else { return .failure(.notTrusted) }
        let host = target.host, browser = target.browser

        // Still the same, allowed page: the user may have moved on while
        // Touch ID asked
        let urls = target.frames.map(Self.url)
        guard let now = LoginSite.allowedHost(frames: urls, websites: websites), now == host,
              Self.bool(target.window, kAXMainAttribute), Self.isFocused(target.field, pid: target.pid) else {
            return .failure(.pageChanged(host: host, browser: browser))
        }

        if target.step == .username {
            guard let username, !username.isEmpty else { return .failure(.noField(host: host, browser: browser)) }
            guard type(username, into: target.field, pid: target.pid),
                  UsernameField.holds(Self.value(target.field, kAXValueAttribute) as? String, username: username) else {
                return .failure(.usernameNotTaken(host: host, browser: browser))
            }
            Self.pressReturn(to: target.pid)
            usleep(Self.usernameWait)
            return .success(.usernameSent)
        }

        guard FillTyping.split(password) != nil else { return .failure(.failed("the password is empty.")) }
        var usedUsername = false
        if let field = target.usernameField, let username, !username.isEmpty {
            if !UsernameField.holds(Self.value(field, kAXValueAttribute) as? String, username: username) {
                guard Self.focus(field, pid: target.pid), type(username, into: field, pid: target.pid),
                      UsernameField.holds(Self.value(field, kAXValueAttribute) as? String, username: username) else {
                    return .failure(.usernameNotTaken(host: host, browser: browser))
                }
            }
            usedUsername = true
            guard Self.focus(target.field, pid: target.pid) else {
                return .failure(.couldNotFocus(host: host, browser: browser))
            }
        }

        guard type(password, into: target.field, pid: target.pid) else {
            clear(target.field)
            return .failure(.failed("macOS didn't let KeyBar type into the browser."))
        }
        let count = (Self.value(target.field, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue ?? -1
        guard FillTyping.holdsWhole(count, of: password) else {
            clear(target.field)
            return .failure(.notTaken(host: host, browser: browser))
        }

        // Sign in straight away, so the password sits in the page for as
        // short a time as possible, then make sure it doesn't stay there
        Self.pressReturn(to: target.pid)
        let deadline = Date().addingTimeInterval(Self.submitWait)
        while Date() < deadline {
            usleep(250_000)
            if !Self.stillHoldsText(target.field) { return .success(.signedIn(usedUsername: usedUsername)) }
        }
        clear(target.field)
        return .success(.stillShowing(usedUsername: usedUsername))
    }

    /// Sets all but the last character as the field's value and types the
    /// last one as a real key press. The field must have the focus.
    private func type(_ text: String, into field: AXUIElement, pid: pid_t) -> Bool {
        guard let (head, last) = FillTyping.split(text) else { return false }
        let set = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, head as CFString)
        guard set == .success else { return false }
        // The key press lands after what's there
        var range = CFRange(location: head.utf16.count, length: 0)
        if let value = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value)
        }
        guard Self.type(last, to: pid) else { return false }
        usleep(Self.settle)
        return true
    }

    /// The field is still on the page with something in it. Gone (the page
    /// moved on) or empty (the page cleared it) both count as no.
    private static func stillHoldsText(_ field: AXUIElement) -> Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(field, kAXNumberOfCharactersAttribute as CFString, &value)
        guard result == .success, let count = (value as? NSNumber)?.intValue else { return false }
        return count > 0
    }

    private static func focus(_ field: AXUIElement, pid: pid_t) -> Bool {
        if isFocused(field, pid: pid) { return true }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(100_000)
        return isFocused(field, pid: pid)
    }

    /// Return, sent to the browser's process: submits the form the focused
    /// field is in
    private static func pressReturn(to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down) else { return }
            event.flags = []
            event.postToPid(pid)
        }
    }

    /// Turns Accessibility back off in a Chromium browser KeyBar turned it on
    /// in. Safe to call more than once.
    func finish(_ target: FillTarget) {
        if let restore = target.restore { Self.turnOffWebAccessibility(restore) }
    }

    private func clear(_ field: AXUIElement) {
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
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
