import Foundation

/// A password field KeyBar could fill: on a page that's on one of the
/// password's websites, in a browser window
struct FillCandidate: Equatable, Sendable {
    var browser: String
    /// The page's host, e.g. accounts.liverpoolfc.com
    var host: String
    /// It has the keyboard focus in its browser
    var focused: Bool
    /// Its window is the browser's main (front) window, where key presses go
    var inMainWindow: Bool
    /// Its browser is the app in front
    var inFrontApp: Bool
}

/// Which field to fill, out of the candidates
enum FillChoice: Equatable, Sendable {
    /// This one; `needsFocus` when KeyBar has to put the cursor in it first
    case fill(Int, needsFocus: Bool)
    case none
    /// More than one, and nothing says which: the user (or Claude) has to
    /// focus the right one
    case several(Int)

    /// The focused field wins. A browser keeps a focused field in each of its
    /// windows, so with several, the one in the front app's front window wins,
    /// then the only one in a front window. With none focused, a lone field
    /// gets the cursor; with more, nobody guesses.
    static func choose(_ candidates: [FillCandidate]) -> FillChoice {
        guard !candidates.isEmpty else { return .none }
        let focused = candidates.indices.filter { candidates[$0].focused }
        if focused.count == 1 { return .fill(focused[0], needsFocus: false) }
        if focused.count > 1 {
            let front = focused.filter { candidates[$0].inFrontApp && candidates[$0].inMainWindow }
            if front.count == 1 { return .fill(front[0], needsFocus: false) }
            let main = focused.filter { candidates[$0].inMainWindow }
            if main.count == 1 { return .fill(main[0], needsFocus: false) }
            return .several(focused.count)
        }
        return candidates.count == 1 ? .fill(0, needsFocus: true) : .several(candidates.count)
    }
}

/// Why a password wasn't filled. Never holds the password, so any of these
/// can go back to Claude and into the activity log.
enum FillProblem: Error, Equatable, Sendable {
    case notTrusted
    case noBrowser
    /// No open https page is on these websites
    case noPage([String])
    /// The page is there, without a password field
    case noField(host: String, browser: String)
    case several(Int)
    case couldNotFocus(host: String, browser: String)
    case notFrontWindow(host: String, browser: String)
    /// Between finding the field and typing, the page moved off the
    /// password's websites or the field lost focus
    case pageChanged(host: String, browser: String)
    /// The field didn't end up with the whole password; it was cleared
    case notTaken(host: String, browser: String)
    case failed(String)

    var message: String {
        switch self {
        case .notTrusted:
            return "KeyBar isn't allowed to fill passwords yet: macOS needs the user to allow KeyBar in System Settings → "
                + "Privacy & Security → Accessibility (KeyBar → Settings → Passwords has a button for it). Ask the user to do that, then try again."
        case .noBrowser:
            return "No browser KeyBar can fill is open. KeyBar fills Safari and Chromium browsers (Chrome, Arc, Brave, Edge, Vivaldi); Firefox isn't supported."
        case .noPage(let sites):
            return "No open page is on \(sites.joined(separator: " or ")) over https, so nothing was filled. Open the login page first "
                + "(KeyBar looks at the tab showing in each browser window)."
        case .noField(let host, let browser):
            return "The page on \(host) in \(browser) has no password field. If the site asks for the username first, do that step, then call fill_password again."
        case .several(let count):
            return "There are \(count) password fields KeyBar could fill. Focus (click into) the right one, then call fill_password again."
        case .couldNotFocus(let host, let browser):
            return "KeyBar couldn't put the cursor in the password field on \(host) in \(browser). Click into the field, then try again."
        case .notFrontWindow(let host, let browser):
            return "The login page on \(host) isn't in \(browser)'s front window, where typing goes. Bring that window to the front, then try again."
        case .pageChanged(let host, let browser):
            return "The page on \(host) in \(browser) changed while KeyBar waited (it left the password's websites, or the password field lost focus), "
                + "so nothing was filled. Focus the password field and try again."
        case .notTaken(let host, let browser):
            return "The password field on \(host) in \(browser) didn't take the password correctly, so KeyBar cleared it. Ask the user to sign in themselves."
        case .failed(let detail):
            return "KeyBar couldn't fill the password: \(detail)"
        }
    }

    /// The page it was about, for the activity log
    var site: String? {
        switch self {
        case .noField(let host, _), .couldNotFocus(let host, _), .notFrontWindow(let host, _),
             .pageChanged(let host, _), .notTaken(let host, _):
            return host
        default:
            return nil
        }
    }

    var browser: String? {
        switch self {
        case .noField(_, let browser), .couldNotFocus(_, let browser), .notFrontWindow(_, let browser),
             .pageChanged(_, let browser), .notTaken(_, let browser):
            return browser
        default:
            return nil
        }
    }
}

/// The browsers KeyBar fills in
struct FillBrowser: Sendable, Equatable {
    let name: String
    let bundleIDs: [String]
    /// Chromium only shows web pages to Accessibility once asked to
    /// (AXManualAccessibility)
    let chromium: Bool

    /// Safari can run several processes with its bundle ID: the usual one and
    /// a separate one for automation (safaridriver). Each is looked at.
    static let all: [FillBrowser] = [
        FillBrowser(name: "Safari", bundleIDs: ["com.apple.Safari"], chromium: false),
        FillBrowser(name: "Safari Technology Preview", bundleIDs: ["com.apple.SafariTechnologyPreview"], chromium: false),
        FillBrowser(name: "Chrome", bundleIDs: ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev"], chromium: true),
        FillBrowser(name: "Chrome Canary", bundleIDs: ["com.google.Chrome.canary"], chromium: true),
        FillBrowser(name: "Chromium", bundleIDs: ["org.chromium.Chromium"], chromium: true),
        FillBrowser(name: "Arc", bundleIDs: ["company.thebrowser.Browser"], chromium: true),
        FillBrowser(name: "Brave", bundleIDs: ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"], chromium: true),
        FillBrowser(name: "Edge", bundleIDs: ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev"], chromium: true),
        FillBrowser(name: "Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"], chromium: true),
    ]
}

/// How a password is typed: all but its last character set as the field's
/// value, then the last one typed as a real key press, so the page's own
/// script sees an input event (React and Vue forms ignore a value that's
/// only set). A one-character password is all typed.
enum FillTyping {
    static func split(_ password: String) -> (head: String, last: String)? {
        guard let last = password.last else { return nil }
        return (String(password.dropLast()), String(last))
    }

    /// Whether the field's character count says it holds the whole password.
    /// Browsers count UTF-16 units; characters and scalars are accepted too.
    static func holdsWhole(_ count: Int, of password: String) -> Bool {
        count > 0 && (count == password.utf16.count || count == password.count || count == password.unicodeScalars.count)
    }
}
