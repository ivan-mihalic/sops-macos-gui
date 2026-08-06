import Foundation

/// A version as printed by a CLI tool or a GitHub release tag.
/// Deliberately lenient: real tools print things like "2.54.0 (Apple Git-157)".
public struct SemanticVersion: Comparable, Equatable, Hashable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" || $0 == "V" })

        var components: [Int] = []
        var current = ""
        for character in trimmed {
            if character.isNumber {
                current.append(character)
            } else if character == "." && components.count < 2 {
                // Empty component between separators is invalid
                guard !current.isEmpty else { return nil }
                guard let n = Int(current) else { return nil }
                components.append(n)
                current = ""
            } else {
                break
            }
        }
        if !current.isEmpty {
            guard let n = Int(current) else { return nil }
            components.append(n)
        }

        guard let major = components.first else { return nil }
        self.init(major, components.count > 1 ? components[1] : 0,
                  components.count > 2 ? components[2] : 0)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
