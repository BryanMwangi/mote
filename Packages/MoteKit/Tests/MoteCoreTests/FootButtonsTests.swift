import Testing

@testable import MoteCore

@Suite("FootButtons")
struct FootButtonsTests {
    @Test("Nothing saved is the standard set; unknown and repeated names go")
    func read() {
        #expect(FootButton.read(nil) == [.profile, .chats, .library])
        #expect(FootButton.read([]) == [])
        #expect(FootButton.read(["downloads", "gone", "downloads", "chats"]) == [.downloads, .chats])
    }

    @Test("Moving stays within the list")
    func moving() {
        let list: [FootButton] = [.chats, .downloads, .library]
        #expect(FootButton.moving(.downloads, by: -1, in: list) == [.downloads, .chats, .library])
        #expect(FootButton.moving(.chats, by: -1, in: list) == list)
        #expect(FootButton.moving(.downloads, by: 5, in: list) == [.chats, .library, .downloads])
        #expect(FootButton.moving(.history, by: 1, in: list) == list)
    }
}
