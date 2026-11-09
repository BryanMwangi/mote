import Foundation

// WebKit keeps some things (the Web Inspector, some feature flags) behind
// selectors it doesn't publish. These call one only after checking the object
// answers to it, so a WebKit without it makes the call do nothing.

extension NSObject {
    /// Runs a method that takes nothing and gives nothing back.
    func unpublished(_ name: String) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        perform(selector)
    }

    /// An object a method gives back.
    func unpublishedObject(_ name: String) -> NSObject? {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return nil }
        return perform(selector)?.takeUnretainedValue() as? NSObject
    }

    /// A Bool a method gives back; `perform` can't carry one.
    func unpublishedFlag(_ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method(for: selector), to: Call.self)(self, selector)
    }

    /// A Bool a method gives back for one argument.
    func unpublishedFlag(_ name: String, _ argument: AnyObject) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(method(for: selector), to: Call.self)(self, selector, argument)
    }

    /// A method taking a Bool and an object.
    func unpublished(_ name: String, _ flag: Bool, _ argument: AnyObject) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(method(for: selector), to: Call.self)(self, selector, flag, argument)
    }

    /// A number a method gives back.
    func unpublishedNumber(_ name: String) -> CGFloat? {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector) -> CGFloat
        return unsafeBitCast(method(for: selector), to: Call.self)(self, selector)
    }

    /// A process id a method gives back (`_webProcessIdentifier`).
    func unpublishedPID(_ name: String) -> pid_t? {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector) -> pid_t
        return unsafeBitCast(method(for: selector), to: Call.self)(self, selector)
    }

    /// A method taking a number.
    func unpublished(_ name: String, _ value: CGFloat) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(method(for: selector), to: Call.self)(self, selector, value)
    }

    /// A method taking a whole number (an NSInteger, as an enum's case).
    func unpublished(_ name: String, whole value: Int) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(method(for: selector), to: Call.self)(self, selector, value)
    }

    /// A whole number a method gives back.
    func unpublishedWhole(_ name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(method(for: selector), to: Call.self)(self, selector)
    }

    /// A method taking a Bool.
    func unpublished(_ name: String, _ flag: Bool) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method(for: selector), to: Call.self)(self, selector, flag)
    }
}
