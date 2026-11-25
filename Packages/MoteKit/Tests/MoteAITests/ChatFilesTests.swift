import Foundation
import Testing

@testable import MoteAI

@Suite("Chat files")
struct ChatFilesTests {
    let place = FileManager.default.temporaryDirectory.appendingPathComponent("ChatFilesTests-\(UUID().uuidString)")

    private func make(_ name: String, _ text: String = "hello") throws -> URL {
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let url = place.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("A file is copied in under its name, numbered when the name is taken, and stays when the original goes")
    func keeps() throws {
        defer { try? FileManager.default.removeItem(at: place) }
        let folder = place.appendingPathComponent("chat")
        let original = try make("cv.pdf")
        let first = try ChatFiles.keep(original, in: folder)
        let second = try ChatFiles.keep(original, in: folder)
        #expect(first == Attachment(file: "cv.pdf", name: "cv.pdf", bytes: 5))
        #expect(second.file == "cv 2.pdf")
        try FileManager.default.removeItem(at: original)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cv.pdf").path))
        #expect(ChatFiles.size(of: folder) > 0)
    }

    @Test("Folders aren't taken; a link is followed to its file")
    func onlyFiles() throws {
        defer { try? FileManager.default.removeItem(at: place) }
        let folder = place.appendingPathComponent("chat")
        let file = try make("notes.txt")
        #expect(throws: ChatFiles.Refusal.notAFile(place.lastPathComponent)) {
            try ChatFiles.keep(place, in: folder)
        }
        let link = place.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try ChatFiles.keep(link, in: folder).name == "notes.txt")
    }

    @Test("Names are kept to one folder and never hidden")
    func clean() {
        #expect(ChatFiles.clean("../../etc/passwd") == "-..-etc-passwd")
        #expect(ChatFiles.clean(".env") == "env")
        #expect(ChatFiles.clean("...") == "File")
    }
}
