import Foundation

/// The websites a stored password is for, and which pages it may be filled
/// into. Compiled into the app and the helper. Matching is on whole host
/// names, never substrings: a password for liverpoolfc.com may go into
/// https://liverpoolfc.com and https://accounts.liverpoolfc.com, but not
/// https://liverpoolfc.com.evil.io, https://evilliverpoolfc.com or any
/// http:// page.
enum LoginSite {
    enum Problem: LocalizedError, Equatable {
        case empty
        case invalid(String)
        case tooBroad(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "Type the website, like liverpoolfc.com."
            case .invalid(let text): return "\"\(text)\" isn't a website. Paste the login page's address, or type a domain like liverpoolfc.com."
            case .tooBroad(let host): return "\(host) is too broad: it would match other people's sites. Use the site's own domain, like liverpoolfc.com."
            }
        }
    }

    /// Endings shared by unrelated sites. Saving one would let a password go
    /// to any site under it. Not the whole public suffix list: a guard
    /// against the usual mistakes.
    static let sharedSuffixes: Set<String> = [
        "co.uk", "org.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "ac.uk", "gov.uk", "nhs.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "co.jp", "ne.jp", "or.jp",
        "co.in", "co.za", "com.br", "com.cn", "com.mx", "com.tr", "com.sg", "com.hk", "co.kr", "co.il",
        "github.io", "gitlab.io", "herokuapp.com", "netlify.app", "vercel.app", "pages.dev", "workers.dev",
        "web.app", "firebaseapp.com", "appspot.com", "azurewebsites.net", "cloudfront.net", "blogspot.com",
        "wordpress.com", "squarespace.com", "myshopify.com", "glitch.me", "fly.dev", "onrender.com",
        "s3.amazonaws.com", "amazonaws.com", "ngrok.io", "ngrok-free.app",
    ]

    /// A pasted address or a typed domain as the lowercase host it's saved
    /// as: "https://www.LiverpoolFC.com/login?x=1" → "liverpoolfc.com". A
    /// leading www. is the site itself, so it's dropped: the password then
    /// also fills on accounts.liverpoolfc.com and the like.
    static func normalise(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Problem.empty }
        let address = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: address), let raw = components.host,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            throw Problem.invalid(trimmed)
        }
        guard let host = canonicalHost(raw) else { throw Problem.invalid(trimmed) }
        if isIPAddress(host) { return host }
        // One word (localhost, com) isn't a website anyone else could reach
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { throw Problem.invalid(trimmed) }
        guard !sharedSuffixes.contains(host) else { throw Problem.tooBroad(host) }
        if host.hasPrefix("www."), let site = try? normalise(String(host.dropFirst(4))) { return site }
        return host
    }

    /// Several websites typed or pasted at once, separated by commas, spaces
    /// or new lines; each one normalised, duplicates dropped
    static func normaliseList(_ text: String) throws -> [String] {
        var hosts: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let host = try normalise(String(part))
            if !hosts.contains(host) { hosts.append(host) }
        }
        return hosts
    }

    /// Lowercase, without a trailing dot; nil for anything a host name can't
    /// hold (percent signs, spaces, a user name)
    static func canonicalHost(_ raw: String) -> String? {
        var host = raw.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253 else { return nil }
        if isIPAddress(host) { return host }
        let allowed = host.unicodeScalars.allSatisfy { scalar in
            scalar == "." || scalar == "-" || scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
        }
        return allowed ? host : nil
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// The host a page's address is on, if a password may be filled there:
    /// https only, on the default port. nil for anything else.
    static func fillableHost(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              let raw = components.host, let host = canonicalHost(raw) else { return nil }
        return host
    }

    /// Whether `host` is one of `websites` or a subdomain of one. IP
    /// addresses must match exactly.
    static func matches(_ host: String, websites: [String]) -> Bool {
        websites.contains { site in
            host == site || (!isIPAddress(site) && !isIPAddress(host) && host.hasSuffix("." + site))
        }
    }

    /// The host a password may be filled into on this page, or nil if it
    /// mayn't. `frames` are the addresses of the page and the frames around
    /// the field, outermost first: every one must be on one of the
    /// password's websites, so a login frame can't be filled inside some
    /// other site's page, nor another site's frame inside the login page.
    static func allowedHost(frames: [URL?], websites: [String]) -> String? {
        guard !frames.isEmpty, !websites.isEmpty else { return nil }
        var host: String?
        for frame in frames {
            guard let frame, let frameHost = fillableHost(frame), matches(frameHost, websites: websites) else { return nil }
            host = frameHost
        }
        return host
    }

    /// The name suggested for a password: LOGIN_ and the site's own name,
    /// "accounts.liverpoolfc.com" → LOGIN_LIVERPOOLFC
    static func suggestedName(for website: String) -> String {
        let host = (try? normalise(website)) ?? website.lowercased()
        if isIPAddress(host) { return SecretName.normalized("LOGIN_" + host) }
        // On a shared host (the-internet.herokuapp.com) the site is the label
        // in front of it
        if let shared = sharedSuffixes.filter({ host.hasSuffix("." + $0) }).max(by: { $0.count < $1.count }),
           let site = host.dropLast(shared.count + 1).split(separator: ".").last {
            return SecretName.normalized("LOGIN_" + site)
        }
        var labels = host.split(separator: ".").map(String.init)
        if labels.count >= 2 { labels.removeLast() }
        // co.uk, com.au and the like: the site's name is the label before
        if labels.count >= 2, ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "ltd", "plc", "me"].contains(labels.last!) {
            labels.removeLast()
        }
        let site = labels.last ?? host
        return SecretName.normalized("LOGIN_" + site)
    }
}
