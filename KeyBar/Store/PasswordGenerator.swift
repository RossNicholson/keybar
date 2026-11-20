import Foundation

/// Makes strong random passwords for the Add form's Generate button: 20
/// characters by default, with lower and upper case letters, digits and
/// symbols (at least one of each, as many sites insist). Uses the system's
/// secure random numbers; never quotes, spaces or backslashes, which some
/// sites mangle.
enum PasswordGenerator {
    static let lower = Array("abcdefghijkmnopqrstuvwxyz")
    static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digits = Array("23456789")
    static let symbols = Array("-_.!@#%*+=?")
    static let defaultLength = 20

    static var allowed: Set<Character> { Set(lower + upper + digits + symbols) }

    static func make(length: Int = defaultLength) -> String {
        var random = SystemRandomNumberGenerator()
        return make(length: length, using: &random)
    }

    static func make<R: RandomNumberGenerator>(length: Int, using random: inout R) -> String {
        let classes = [lower, upper, digits, symbols]
        let length = max(length, classes.count)
        let all = classes.flatMap { $0 }
        // One from each class, the rest from all of them, then shuffled so
        // the classes' places aren't predictable
        var characters = classes.map { $0.randomElement(using: &random)! }
        while characters.count < length { characters.append(all.randomElement(using: &random)!) }
        characters.shuffle(using: &random)
        return String(characters)
    }
}
