import CoreGraphics

/// The side of the window a side panel docks on.
public enum PanelSide: String, Codable, Sendable {
    case left, right
}

/// Where a panel goes among the others on its side.
public enum PanelPlacement: String, Codable, Sendable {
    /// Beside the page, the newest nearest it.
    case normal
    /// At the outer edge of its side (against the sidebar when that is on the
    /// same side), whatever else opens: the chat.
    case edgeAlways
}

/// A side panel as the layout sees it: what it shows is the browser's
/// business, so any page or view can be one.
public struct PanelSlot: Equatable, Sendable {
    public let id: String
    public let side: PanelSide
    public let width: CGFloat
    public let placement: PanelPlacement

    public init(id: String, side: PanelSide, width: CGFloat, placement: PanelPlacement = .normal) {
        self.id = id
        self.side = side
        self.width = width
        self.placement = placement
    }

    /// The panels of one side from its outer edge inwards: the edge ones,
    /// then the others in the order they opened, so the newest is beside
    /// the page. `slots` are in opening order.
    public static func fromEdge(_ slots: [PanelSlot], on side: PanelSide) -> [PanelSlot] {
        let here = slots.filter { $0.side == side }
        return here.filter { $0.placement == .edgeAlways } + here.filter { $0.placement == .normal }
    }
}

/// A panel placed in the window.
public struct PlacedPanel: Equatable, Sendable {
    public let id: String
    public let side: PanelSide
    public let frame: CGRect
}
