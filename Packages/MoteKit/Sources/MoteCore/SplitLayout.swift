import CoreGraphics

/// Side by side, or stacked.
public enum SplitAxis: String, Codable, Sendable {
    case across, down
}

/// Where a tab dropped on a page goes, beside the page it's dropped on.
public enum SplitSide: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom

    public var axis: SplitAxis { self == .left || self == .right ? .across : .down }
    /// Before the page it's beside: on the left or on top.
    public var before: Bool { self == .left || self == .top }
}

/// Zen's three layouts for a group's tabs.
public enum SplitGrid: String, Codable, Sendable {
    case grid, across, down
}

/// A split view: up to four tabs laid out as a tree of rows and columns,
/// each child with its share of its parent, as Zen's split view keeps them
/// (`ZenViewSplitter.mjs`). Rectangles are measured from the top left.
public struct SplitLayout<ID: Hashable & Codable & Sendable>: Codable, Equatable, Sendable {
    public indirect enum Node: Codable, Equatable, Sendable {
        case leaf(ID)
        case split(SplitAxis, [Child])
    }

    public struct Child: Codable, Equatable, Sendable {
        public var node: Node
        /// Of its parent, 0 to 1; a parent's children's add up to 1.
        public var share: CGFloat
    }

    /// A line between two children, to drag.
    public struct Divider: Equatable, Sendable {
        /// The split, by child index from the root.
        public let path: [Int]
        /// Between children `index` and `index + 1`.
        public let index: Int
        public let axis: SplitAxis
        public let rect: CGRect
        /// The split's whole rectangle, which the shares divide.
        public let span: CGRect
    }

    public static var most: Int { 4 }
    /// No pane is narrower than this share of its split.
    public static var least: CGFloat { 0.15 }

    public private(set) var root: Node

    public init(_ id: ID) { root = .leaf(id) }

    init(root: Node) { self.root = root }

    /// The same layout over other ids, say a session's positions for tabs'
    /// ids: tabs `transform` drops leave, and fewer than two make nil.
    public func compactMap<Other>(_ transform: (ID) -> Other?) -> SplitLayout<Other>? {
        func map(_ node: Node) -> SplitLayout<Other>.Node? {
            switch node {
            case .leaf(let id): return transform(id).map { .leaf($0) }
            case .split(let axis, let children):
                let kept = children.compactMap { child in map(child.node).map { SplitLayout<Other>.Child(node: $0, share: child.share) } }
                guard !kept.isEmpty else { return nil }
                if kept.count == 1 { return kept[0].node }
                let total = kept.reduce(0) { $0 + $1.share }
                return .split(axis, kept.map { .init(node: $0.node, share: $0.share / max(total, .ulpOfOne)) })
            }
        }
        guard let root = map(root) else { return nil }
        let made = SplitLayout<Other>(root: root)
        return made.count > 1 ? made : nil
    }

    public var ids: [ID] { Self.ids(in: root) }
    public var count: Int { ids.count }
    public func contains(_ id: ID) -> Bool { ids.contains(id) }

    private static func ids(in node: Node) -> [ID] {
        switch node {
        case .leaf(let id): [id]
        case .split(_, let children): children.flatMap { ids(in: $0.node) }
        }
    }

    // MARK: - Changing it

    /// Puts `id` beside `target` on `side`, halving `target`'s room. False,
    /// changing nothing, when the group is full, `id` is in it, or `target` isn't.
    @discardableResult
    public mutating func insert(_ id: ID, beside target: ID, side: SplitSide) -> Bool {
        guard count < Self.most, !contains(id), contains(target) else { return false }
        root = Self.insert(id, beside: target, side: side, in: root)
        return true
    }

    private static func insert(_ id: ID, beside target: ID, side: SplitSide, in node: Node) -> Node {
        switch node {
        case .leaf(let here):
            guard here == target else { return node }
            let pair = [Child(node: .leaf(here), share: 0.5), Child(node: .leaf(id), share: 0.5)]
            return .split(side.axis, side.before ? pair.reversed() : pair)
        case .split(let axis, var children):
            // Beside a direct child along this split's own axis: a sibling.
            if axis == side.axis, let at = children.firstIndex(where: { $0.node == .leaf(target) }) {
                let half = children[at].share / 2
                children[at].share = half
                children.insert(Child(node: .leaf(id), share: half), at: side.before ? at : at + 1)
                return .split(axis, children)
            }
            for index in children.indices { children[index].node = insert(id, beside: target, side: side, in: children[index].node) }
            return .split(axis, children)
        }
    }

    /// Takes `id` out; its room goes to its neighbours, and a split left with
    /// one child becomes that child. False when it wasn't there.
    @discardableResult
    public mutating func remove(_ id: ID) -> Bool {
        guard contains(id), count > 1 else { return false }
        root = Self.remove(id, from: root)
        return true
    }

    private static func remove(_ id: ID, from node: Node) -> Node {
        guard case .split(let axis, var children) = node else { return node }
        if let at = children.firstIndex(where: { $0.node == .leaf(id) }) {
            let freed = children.remove(at: at).share
            let rest = children.reduce(0) { $0 + $1.share }
            for index in children.indices { children[index].share += freed * children[index].share / max(rest, .ulpOfOne) }
        } else {
            for index in children.indices { children[index].node = remove(id, from: children[index].node) }
        }
        return children.count == 1 ? children[0].node : .split(axis, children)
    }

    /// Moves a divider so its line falls at `position` (along its axis, in the
    /// same space as its `span`), neither side below `least`.
    public mutating func move(_ divider: Divider, to position: CGFloat) {
        root = Self.move(divider, to: position, in: root, path: divider.path[...])
    }

    private static func move(_ divider: Divider, to position: CGFloat, in node: Node, path: ArraySlice<Int>) -> Node {
        guard case .split(let axis, var children) = node else { return node }
        if let next = path.first {
            children[next].node = move(divider, to: position, in: children[next].node, path: path.dropFirst())
            return .split(axis, children)
        }
        let i = divider.index
        guard children.indices.contains(i + 1) else { return node }
        let length = axis == .across ? divider.span.width : divider.span.height
        let origin = axis == .across ? divider.span.minX : divider.span.minY
        guard length > 0 else { return node }
        let before = children[..<i].reduce(0) { $0 + $1.share }
        let pair = children[i].share + children[i + 1].share
        let wanted = (position - origin) / length - before
        let first = min(max(wanted, least), pair - least)
        children[i].share = first
        children[i + 1].share = pair - first
        return .split(axis, children)
    }

    /// The tabs laid out afresh, as Zen's `calculateLayoutTree`: side by side,
    /// stacked, or two to a column for a grid.
    public static func layout(_ grid: SplitGrid, _ ids: [ID]) -> SplitLayout? {
        guard let first = ids.first, ids.count <= most else { return nil }
        var made = SplitLayout(first)
        guard ids.count > 1 else { return made }
        let even = { (nodes: [Node]) in nodes.map { Child(node: $0, share: 1 / CGFloat(nodes.count)) } }
        switch grid {
        case .across: made.root = .split(.across, even(ids.map(Node.leaf)))
        case .down: made.root = .split(.down, even(ids.map(Node.leaf)))
        case .grid:
            guard ids.count > 2 else {
                made.root = .split(.across, even(ids.map(Node.leaf)))
                return made
            }
            let columns = stride(from: 0, to: ids.count, by: 2).map { start -> Node in
                let pair = ids[start..<min(start + 2, ids.count)]
                return pair.count == 2 ? .split(.down, even(pair.map(Node.leaf))) : .leaf(pair[pair.startIndex])
            }
            made.root = .split(.across, even(columns))
        }
        return made
    }

    // MARK: - Where things go

    /// Each tab's rectangle in `rect`, with `gap` between neighbours.
    public func frames(in rect: CGRect, gap: CGFloat) -> [ID: CGRect] {
        var found: [ID: CGRect] = [:]
        Self.walk(root, in: rect, gap: gap, path: []) { node, frame, _ in
            if case .leaf(let id) = node { found[id] = frame }
        }
        return found
    }

    /// The lines between neighbours, `gap` thick.
    public func dividers(in rect: CGRect, gap: CGFloat) -> [Divider] {
        var found: [Divider] = []
        Self.walk(root, in: rect, gap: gap, path: []) { node, frame, path in
            guard case .split(let axis, let children) = node else { return }
            var edge = axis == .across ? frame.minX : frame.minY
            let length = (axis == .across ? frame.width : frame.height) - gap * CGFloat(children.count - 1)
            for (index, child) in children.dropLast().enumerated() {
                edge += child.share * length
                let line =
                    axis == .across
                    ? CGRect(x: edge, y: frame.minY, width: gap, height: frame.height)
                    : CGRect(x: frame.minX, y: edge, width: frame.width, height: gap)
                found.append(Divider(path: path, index: index, axis: axis, rect: line, span: frame))
                edge += gap
            }
        }
        return found
    }

    private static func walk(_ node: Node, in frame: CGRect, gap: CGFloat, path: [Int], _ visit: (Node, CGRect, [Int]) -> Void) {
        visit(node, frame, path)
        guard case .split(let axis, let children) = node else { return }
        let length = (axis == .across ? frame.width : frame.height) - gap * CGFloat(children.count - 1)
        var edge = axis == .across ? frame.minX : frame.minY
        for (index, child) in children.enumerated() {
            let size = child.share * length
            let part =
                axis == .across
                ? CGRect(x: edge, y: frame.minY, width: size, height: frame.height)
                : CGRect(x: frame.minX, y: edge, width: frame.width, height: size)
            walk(child.node, in: part, gap: gap, path: path + [index], visit)
            edge += size + gap
        }
    }

    /// Zen's rule: the nearest edge of `rect` within a quarter of its width
    /// or height from `point`; none in the middle.
    public static func dropSide(at point: CGPoint, in rect: CGRect) -> SplitSide? {
        guard rect.contains(point) else { return nil }
        let edges: [(SplitSide, CGFloat, CGFloat)] = [
            (.left, point.x - rect.minX, rect.width / 4), (.right, rect.maxX - point.x, rect.width / 4),
            (.top, point.y - rect.minY, rect.height / 4), (.bottom, rect.maxY - point.y, rect.height / 4),
        ]
        return edges.filter { $0.1 < $0.2 }.min { $0.1 < $1.1 }?.0
    }

    /// Where a tab dropped beside `target` on `side` would show: that half of it.
    public static func preview(of target: CGRect, side: SplitSide) -> CGRect {
        switch side {
        case .left: CGRect(x: target.minX, y: target.minY, width: target.width / 2, height: target.height)
        case .right: CGRect(x: target.midX, y: target.minY, width: target.width / 2, height: target.height)
        case .top: CGRect(x: target.minX, y: target.minY, width: target.width, height: target.height / 2)
        case .bottom: CGRect(x: target.minX, y: target.midY, width: target.width, height: target.height / 2)
        }
    }
}
