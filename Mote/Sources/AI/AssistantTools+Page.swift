import AppKit
import MoteAI
import MoteCore
import WebKit

/// Inside a page: reading it with what can be clicked or typed into, and
/// clicking and typing there.
extension AssistantTools {
    var pageTools: [Tool] {
        let tab = #""tab":{"type":"string","description":"A tab id from list_tabs"}"#
        var tools = [
            Tool(
                name: "read_tab",
                description: "An open tab's text, and a numbered list of what can be clicked or typed into on it, for click and fill.",
                schema: "{\"type\":\"object\",\"properties\":{\(tab)},\"required\":[\"tab\"]}")
        ]
        guard acts else { return tools }
        let element = "\(tab),\"element\":{\"type\":\"integer\",\"description\":\"Its number from read_tab\"}"
        tools += [
            Tool(
                name: "click", description: "Clicks an element read_tab listed. Asks first, per site.",
                schema: "{\"type\":\"object\",\"properties\":{\(element)},\"required\":[\"tab\",\"element\"]}"),
            Tool(
                name: "fill", description: "Types text into a field read_tab listed. Asks first, per site. Never passwords.",
                schema: "{\"type\":\"object\",\"properties\":{\(element),\"text\":{\"type\":\"string\"}},\"required\":[\"tab\",\"element\",\"text\"]}"),
        ]
        return tools
    }

    func runPage(_ call: ToolCall) async -> String? {
        switch call.name {
        case "read_tab":
            guard let found = find(call.input) else { return "There's no open tab with that id; list the tabs again." }
            let tab = found.tab
            _ = tab.wake()
            let text = await tab.capturePageContext()?.text ?? ""
            let outline = await outline(of: tab)
            return "\(tab.label)\n\(tab.address?.absoluteString ?? "")\n\n\(String(text.prefix(Self.most)))\n\nElements:\n\(outline)"
        case "click", "fill":
            return await act(call)
        default:
            return nil
        }
    }

    private func act(_ call: ToolCall) async -> String {
        let input = call.input
        guard let found = find(input), let number = input["element"]?.int else { return "No such tab or element; read the tab again." }
        let tab = found.tab
        guard let address = tab.address else { return "That tab has no page." }
        let filling = call.name == "fill"
        let text = input["text"]?.string ?? ""
        let what = await label(of: number, in: tab) ?? "element \(number)"
        let question =
            filling
            ? "Type “\(text.prefix(60))” into “\(what)” on \(Address.siteName(for: address))?" : "Click “\(what)” on \(Address.siteName(for: address))?"
        guard await permit(.inPage(address), question) else { return acts ? Self.declined : Self.actingOff }
        // The page mustn't have moved to another site while asked.
        guard Address.siteHost(of: tab.address) == Address.siteHost(of: address) else { return "The page changed; read the tab again." }
        let script = """
            const el = window.__moteOutline?.[n];
            if (!el || !el.isConnected) return 'gone';
            el.scrollIntoView({ block: 'center' });
            if (!fill) { el.click(); return 'done'; }
            if (el.type === 'password') return 'password';
            el.focus();
            if (el.isContentEditable) { el.textContent = text; }
            else {
              const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
              Object.getOwnPropertyDescriptor(proto, 'value')?.set?.call(el, text);
            }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return 'done';
            """
        let result = await withCheckedContinuation { done in
            tab.web.callInAppWorld(script, arguments: ["n": number, "fill": filling, "text": text]) { done.resume(returning: $0 as? String) }
        }
        switch result {
        case "done": return filling ? "Typed." : "Clicked."
        case "password": return "Mote doesn't type into password fields."
        default: return "Element \(number) is gone: the page changed; read the tab again."
        }
    }

    /// What can be clicked or typed into, numbered, remembered in Mote's own
    /// world for click and fill. Password fields are listed, never their values.
    private func outline(of tab: Tab) async -> String {
        let script = """
            const picked = [...document.querySelectorAll('a[href],button,input:not([type=hidden]),select,textarea,[role=button],[role=link],[contenteditable=true]')]
              .filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; }).slice(0, 200);
            window.__moteOutline = picked;
            return picked.map((e, i) => {
              const kind = e.tagName.toLowerCase() + (e.type ? '(' + e.type + ')' : '');
              const words = (e.innerText || e.getAttribute('aria-label') || e.placeholder || e.title
                || (['submit', 'button'].includes(e.type) ? e.value : '') || '').trim().replace(/\\s+/g, ' ').slice(0, 80);
              return '[' + i + '] ' + kind + ' ' + words + (e.href ? ' -> ' + e.href : '');
            }).join('\\n');
            """
        return await withCheckedContinuation { done in
            tab.web.callInAppWorld(script, arguments: [:]) { done.resume(returning: ($0 as? String) ?? "") }
        }
    }

    private func label(of number: Int, in tab: Tab) async -> String? {
        let script = """
            const e = window.__moteOutline?.[n];
            return e ? (e.innerText || e.getAttribute('aria-label') || e.placeholder || e.name || '').trim().slice(0, 60) : null;
            """
        return await withCheckedContinuation { done in
            tab.web.callInAppWorld(script, arguments: ["n": number]) { done.resume(returning: ($0 as? String).flatMap { $0.isEmpty ? nil : $0 }) }
        }
    }
}
