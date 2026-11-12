import Foundation

/// A key Find keys could import: one value, perhaps found in several places
struct ScanCandidate: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable {
        /// Not in KeyBar yet, under the name it has in its files
        case new
        /// Not in KeyBar yet, but its name is taken by another value, so it
        /// gets another one (MADROBOT_STRIPE_SECRET_KEY)
        case renamed
        /// KeyBar already has this value, under `name`
        case stored
    }

    let id = UUID()
    /// The variable name in the files it was found in
    var variable: String
    var value: String
    var sources: [KeySource]
    /// The name it's stored under
    var name: String
    var group: String?
    var status: Status
    var include: Bool

    var record: SecretRecord { SecretRecord(name: variable, createdAt: .now, updatedAt: .now) }

    /// "MadRobot/.env", or "MadRobot/.env and 2 more"
    var whereFound: String {
        guard let first = sources.first else { return "" }
        return sources.count == 1 ? first.label : "\(first.label) and \(sources.count - 1) more"
    }
}

/// Turns what Find keys found into what to import: one candidate per value,
/// no name used twice, and values KeyBar already has marked as stored
enum ScanPlan {
    /// - Parameters:
    ///   - stored: the names KeyBar has
    ///   - storedName: the stored key holding a value, if any
    static func make(_ found: [FoundKey], stored: Set<String>, storedName: (String) -> String?) -> [ScanCandidate] {
        // One candidate per name and value, keeping where each was found
        var order: [String] = []
        var byKey: [String: (variable: String, value: String, sources: [KeySource])] = [:]
        for key in found {
            let id = key.name + "\u{1F}" + key.value
            if byKey[id] == nil {
                order.append(id)
                byKey[id] = (key.name, key.value, [])
            }
            if !(byKey[id]!.sources.contains(key.source)) { byKey[id]!.sources.append(key.source) }
        }

        var candidates: [ScanCandidate] = order.compactMap { id in
            guard let entry = byKey[id] else { return nil }
            let projects = Set(entry.sources.compactMap(\.project))
            let group = projects.count == 1 && entry.sources.allSatisfy { $0.project != nil } ? projects.first : nil
            if let name = storedName(entry.value) {
                return ScanCandidate(variable: entry.variable, value: entry.value, sources: entry.sources, name: name,
                                     group: group, status: .stored, include: false)
            }
            return ScanCandidate(variable: entry.variable, value: entry.value, sources: entry.sources,
                                 name: entry.variable, group: group, status: .new, include: true)
        }

        // A name with more than one new value, or one KeyBar uses for another
        // value, is taken: each of those gets its project's name in front
        let newOnes = candidates.indices.filter { candidates[$0].status == .new }
        let counts = Dictionary(grouping: newOnes, by: { candidates[$0].variable }).mapValues(\.count)
        var taken = stored
        for index in newOnes where counts[candidates[index].variable] == 1 && !stored.contains(candidates[index].variable) {
            taken.insert(candidates[index].variable)
        }
        for index in newOnes where counts[candidates[index].variable]! > 1 || stored.contains(candidates[index].variable) {
            let name = uniqueName(for: candidates[index], taken: taken)
            candidates[index].name = name
            candidates[index].status = .renamed
            taken.insert(name)
        }
        return candidates
    }

    /// MADROBOT_STRIPE_SECRET_KEY for MadRobot's, else STRIPE_SECRET_KEY_2, _3…
    static func uniqueName(for candidate: ScanCandidate, taken: Set<String>) -> String {
        if let project = candidate.group ?? candidate.sources.first?.project {
            let prefix = SecretName.normalized(project.split(separator: "/").first.map(String.init) ?? project)
            if !prefix.isEmpty, !candidate.variable.hasPrefix(prefix + "_") {
                let name = prefix + "_" + candidate.variable
                if SecretName.isValid(name), !taken.contains(name) { return name }
            }
        }
        var number = 2
        while taken.contains("\(candidate.variable)_\(number)") { number += 1 }
        return "\(candidate.variable)_\(number)"
    }
}

/// Swaps the values in a .env file for keybar: references to where they're
/// stored, so the file no longer holds the keys. `keybar run` sets them.
enum EnvRewriter {
    struct Result: Equatable {
        var text: String
        /// Variables swapped for references
        var swapped: [String]
        /// Variables left as they were (a value over several lines)
        var skipped: [String]
    }

    /// - Parameter references: variable → (the value it should have, the stored
    ///   key holding it). A line is only changed when its value matches.
    static func rewrite(_ text: String, references: [String: (value: String, stored: String)]) -> Result {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.components(separatedBy: newline)
        var output: [String] = []
        var swapped: [String] = []
        var skipped: [String] = []
        for line in lines {
            let entries = EnvFile.parse(line)
            guard entries.count == 1, let entry = entries.first, let reference = references[entry.name] else {
                output.append(line)
                continue
            }
            // A line the file's own parse reads differently (an opened quote
            // that runs on to the next lines) is left alone
            guard entry.value == reference.value else {
                if line.contains("\"") { skipped.append(entry.name) }
                output.append(line)
                continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let exported = line.dropFirst(indent.count).hasPrefix("export ") ? "export " : ""
            output.append("\(indent)\(exported)\(entry.name)=\(EnvFile.referencePrefix)\(reference.stored)")
            swapped.append(entry.name)
        }
        return Result(text: output.joined(separator: newline), swapped: swapped, skipped: skipped)
    }
}
