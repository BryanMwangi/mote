import Foundation

/// The profiles listed in a Firefox-family browser's `profiles.ini`, with
/// the default from `installs.ini` (where newer builds keep it) or the
/// profile marked `Default=1`.
public struct FirefoxProfile: Equatable, Sendable {
    public var name: String
    /// The folder, relative to the browser's folder unless `IsRelative=0`.
    public var path: String
    public var isRelative: Bool
    public var isDefault: Bool
}

public enum FirefoxProfiles {
    public static func parse(profiles: String, installs: String? = nil) -> [FirefoxProfile] {
        let installDefaults = Set(sections(installs ?? "").compactMap { $0.values["Default"] })
        var found = sections(profiles).filter { $0.name.hasPrefix("Profile") }.compactMap { section -> FirefoxProfile? in
            guard let path = section.values["Path"], !path.isEmpty else { return nil }
            return FirefoxProfile(
                name: section.values["Name"] ?? path, path: path, isRelative: section.values["IsRelative"] != "0",
                isDefault: installDefaults.contains(path))
        }
        // Older files say it in the profile's own section.
        if !found.contains(where: \.isDefault) {
            let marked = sections(profiles).first { $0.name.hasPrefix("Profile") && $0.values["Default"] == "1" }?.values["Path"]
            if let index = found.firstIndex(where: { $0.path == marked }) { found[index].isDefault = true }
        }
        // The default first.
        return found.filter(\.isDefault) + found.filter { !$0.isDefault }
    }

    private struct Section {
        var name: String
        var values: [String: String] = [:]
    }

    private static func sections(_ text: String) -> [Section] {
        var all: [Section] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                all.append(Section(name: String(line.dropFirst().dropLast())))
            } else if let equals = line.firstIndex(of: "="), !all.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                all[all.count - 1].values[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return all
    }
}
