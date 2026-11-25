import Foundation

/// A chat's own files, in its folder (`ChatArchive.files(of:)`): copies of
/// what the person attaches, so they stay when the original moves or goes,
/// and pictures its steps take. Only plain files are taken, within limits.
public enum ChatFiles {
    /// The most one file may be.
    public static let mostBytes: Int64 = 100_000_000
    /// The most a chat's folder may hold.
    public static let mostInChat: Int64 = 1_000_000_000
    /// The most files on one message.
    public static let mostAtOnce = 10

    public enum Refusal: Error, LocalizedError, Equatable {
        case notAFile(String)
        case tooBig(String)
        case full

        public var errorDescription: String? {
            switch self {
            case .notAFile(let name): "“\(name)” isn't a file Mote can attach."
            case .tooBig(let name): "“\(name)” is over \(ChatFiles.size(ChatFiles.mostBytes)), more than a chat takes."
            case .full: "This chat's files are at \(ChatFiles.size(ChatFiles.mostInChat)); delete some chats' files in Settings › AI."
            }
        }
    }

    /// Copies the file at `url` into `folder`, named as it was (numbered when
    /// the name is taken). A link is followed to its file; folders, packages
    /// and anything not a plain readable file are refused.
    public static func keep(_ url: URL, in folder: URL) throws -> Attachment {
        let real = url.resolvingSymlinksInPath()
        let name = real.lastPathComponent
        let values = try? real.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .fileSizeKey, .isReadableKey])
        guard values?.isRegularFile == true, values?.isPackage != true, values?.isReadable == true else { throw Refusal.notAFile(name) }
        let bytes = Int64(values?.fileSize ?? 0)
        guard bytes <= mostBytes else { throw Refusal.tooBig(name) }
        guard size(of: folder) + bytes <= mostInChat else { throw Refusal.full }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = free(Self.clean(name), in: folder)
        try FileManager.default.copyItem(at: real, to: copy)
        return Attachment(file: copy.lastPathComponent, name: name, bytes: bytes)
    }

    /// Keeps a step's picture; its name in `folder`.
    public static func picture(_ data: Data, in folder: URL) -> String? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Picture \(UUID().uuidString.prefix(8)).jpg")
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file.lastPathComponent
    }

    /// What a folder holds, in bytes; 0 when it isn't there.
    public static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walk {
            let values = try? file.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    public static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// A name safe in one folder: no path separators, not hidden.
    static func clean(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "File" : cleaned
    }

    /// `name` in `folder`, or "name 2.ext" and on while it's taken.
    private static func free(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name), count = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(count)" : "\(base) \(count).\(ext)")
            count += 1
        }
        return candidate
    }
}
