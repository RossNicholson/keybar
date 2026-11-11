import Foundation
import Security

/// Code-signature checks both ends of the socket make: the app only answers
/// its own helper, and the helper only takes keys from the app, each signed
/// by the same Apple developer team.
enum CodeIdentity {
    /// The team this program is signed by, or nil for an unsigned local build
    static let teamID: String? = {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// "Signed by Apple's CA for our team, as `identifier`". Nil if this copy
    /// isn't signed with a team.
    static func requirement(identifier: String) -> SecRequirement? {
        guard let teamID else { return nil }
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(identifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Whether the process at the other end of a connected Unix socket is this
    /// user's and meets `requirement`. Without a requirement (an unsigned
    /// development build) only debug builds let it through.
    static func peer(_ fd: Int32, meets requirement: SecRequirement?) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }

        guard let requirement else {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
        // The audit token names the exact process, so a pid that's been reused
        // can't stand in for it
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
