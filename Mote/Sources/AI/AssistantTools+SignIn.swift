import AppKit
import MoteAI
import MoteCore

/// Signing in for the person: with a password saved in Mote, on sites
/// they've let it sign in to, or with what they type into Mote's own sheet.
/// Either way the password goes from Mote into the page and never to the model.
extension AssistantTools {
    var signInTools: [Tool] {
        let tab = #""tab":{"type":"string","description":"A tab id from list_tabs"}"#
        return [
            Tool(
                name: "sign_in",
                description:
                    "Fills a tab's sign-in with a password saved in Mote for its site (the first account, or the one named). Mote asks the person the first time for each site, and may ask for Touch ID; you never see the password. Submit it afterwards with press_key Enter or a click.",
                schema: "{\"type\":\"object\",\"properties\":{\(tab),\"account\":{\"type\":\"string\"}},\"required\":[\"tab\"]}"),
            Tool(
                name: "ask_for_credentials",
                description:
                    "Asks the person, in a Mote window over the page, for a username, password and any one-time code, and fills them into the tab's sign-in. You never see what they type.",
                schema: "{\"type\":\"object\",\"properties\":{\(tab),\"why\":{\"type\":\"string\"}},\"required\":[\"tab\"]}"),
        ]
    }

    func runSignIn(_ call: ToolCall) async -> String? {
        guard ["sign_in", "ask_for_credentials"].contains(call.name) else { return nil }
        guard acts, !planning else { return refused }
        guard let found = find(call.input) else { return "There's no open tab with that id; list the tabs again." }
        let tab = found.tab
        guard let address = tab.address, let site = browser.logins.accounts(for: tab) else { return "That tab has no site to sign in to." }
        if found.browser.active !== tab || found.parked { bringForward(found) }
        if call.name == "ask_for_credentials" { return await askForCredentials(tab, why: call.input["why"]?.string) }
        guard !site.logins.isEmpty else {
            return "Mote has no saved password for \(site.host). ask_for_credentials asks the person instead."
        }
        let wanted = call.input["account"]?.string?.lowercased()
        let login = site.logins.first { wanted == nil || $0.user.lowercased() == wanted } ?? site.logins[0]
        // The first time on a site, the person says yes, once for good.
        if !SiteList.contains(prefs.aiSignIn, address) {
            guard
                await permit(
                    .destructive,
                    "Let the assistant sign in to \(site.host) as \(login.user.isEmpty ? "your saved account" : login.user)? It fills your saved password into the page and never sees it.")
            else { return Self.declined }
            prefs.aiSignIn = SiteList.adding(site.host, to: prefs.aiSignIn)
        }
        tab.agent.begin("Signing in as \(login.user)", by: driver, stop: stopTurn)
        defer { tab.agent.end() }
        // Through the same fill as the person's own, with Touch ID if they've asked for it.
        browser.logins.fill(login, in: tab, host: site.host, clear: site.clear)
        return "Filled the sign-in as \(login.user.isEmpty ? "the saved account" : login.user). Submit it with press_key Enter or a click; read the tab after to see it worked."
    }

    /// Mote's own sheet: what's typed goes into the page, never to the model.
    private func askForCredentials(_ tab: Tab, why: String?) async -> String {
        let alert = NSAlert()
        alert.messageText = "Sign in to \(tab.address.map { Address.siteName(for: $0) } ?? "this site") for the assistant"
        alert.informativeText = (why.map { $0 + "\n\n" } ?? "") + "What you type goes into the page. The assistant never sees it."
        let user = NSTextField(frame: NSRect(x: 0, y: 64, width: 260, height: 24))
        user.placeholderString = "Username or email"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        password.placeholderString = "Password"
        let code = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        code.placeholderString = "One-time code (if asked)"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 88))
        [user, password, code].forEach(fields.addSubview)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user
        let answer: NSApplication.ModalResponse
        if let window = browser.window {
            answer = await withCheckedContinuation { done in alert.beginSheetModal(for: window) { done.resume(returning: $0) } }
        } else {
            answer = alert.runModal()
        }
        guard answer == .alertFirstButtonReturn, !password.stringValue.isEmpty else { return "The person didn't sign in." }
        tab.agent.begin("Signing in", by: driver, stop: stopTurn)
        defer { tab.agent.end() }
        let filled = await withCheckedContinuation { done in
            tab.fill(user: user.stringValue, password: password.stringValue) { done.resume(returning: $0) }
        }
        guard filled else { return "The page's sign-in fields weren't found; read the tab to see where they are." }
        var codeNote = ""
        if !code.stringValue.isEmpty, await page(tab, "code", ["text": code.stringValue]) != "done" {
            codeNote = " The one-time code had no field yet; it may come on the next page, and ask_for_credentials can ask again."
        }
        return "Filled what the person typed. Submit it with press_key Enter or a click; Mote will offer to save the password once it works." + codeNote
    }
}
