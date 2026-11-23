import CoreGraphics

/// What the forms script in a page reports (see Scripts/src/forms.ts).
public enum FormEvent: Equatable, Sendable {
    /// A sign-in form was sent with these credentials.
    case sent(user: String, password: String)
    /// The sign-in fields went away without a new page.
    case settled
    /// Focus moved. `typing` when it is in something editable; `field` is the
    /// focused sign-in field's frame in CSS pixels, if it is one, and
    /// `contact` a field's asking for the person's details (name, email, address).
    case focus(typing: Bool, field: CGRect?, contact: CGRect? = nil)
    /// The page's own word on full screen.
    case fullscreen(Bool)
    /// A menu is opening on the page: on a sign-in field, or elsewhere (nil).
    case menu(Field?)

    /// A sign-in field: the password's, or the account's name.
    public enum Field: String, Sendable {
        case password, user
    }

    /// Reads a message body; nil for anything unknown.
    public init?(_ body: Any) {
        guard let body = body as? [String: Any], let kind = body["kind"] as? String else { return nil }
        switch kind {
        case "submit":
            self = .sent(user: body["user"] as? String ?? "", password: body["password"] as? String ?? "")
        case "settled":
            self = .settled
        case "focus":
            let frame = { (rect: [String: Double]?) in
                rect.flatMap { rect -> CGRect? in
                    guard let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] else { return nil }
                    return CGRect(x: x, y: y, width: w, height: h)
                }
            }
            self = .focus(
                typing: body["typing"] as? Bool ?? false, field: frame(body["rect"] as? [String: Double]),
                contact: frame(body["contact"] as? [String: Double]))
        case "fullscreen":
            self = .fullscreen(body["on"] as? Bool ?? false)
        case "menu":
            self = .menu((body["field"] as? String).flatMap(Field.init))
        default:
            return nil
        }
    }
}
