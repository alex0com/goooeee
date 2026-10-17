import Foundation

/// A conversation's messages arranged as a tree (as in the llama.cpp UI).
///
/// Editing a user message or regenerating an answer adds a sibling; the conversation's
/// `currentLeafID` selects which branch is shown and sent to the model.
public struct MessageTree: Sendable {
    public private(set) var messages: [UUID: Message]
    private var childrenByParent: [UUID?: [UUID]]

    public init(_ messages: [Message]) {
        self.messages = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.childrenByParent = [:]
        rebuildIndex()
    }

    private mutating func rebuildIndex() {
        var index: [UUID?: [UUID]] = [:]
        for message in messages.values {
            index[message.parentID, default: []].append(message.id)
        }
        for key in index.keys {
            index[key]?.sort { lhs, rhs in
                let left = messages[lhs]!, right = messages[rhs]!
                return left.createdAt == right.createdAt ? lhs.uuidString < rhs.uuidString : left.createdAt < right.createdAt
            }
        }
        childrenByParent = index
    }

    public var isEmpty: Bool { messages.isEmpty }

    public subscript(id: UUID) -> Message? { messages[id] }

    public mutating func upsert(_ message: Message) {
        let isNew = messages[message.id] == nil || messages[message.id]?.parentID != message.parentID
        messages[message.id] = message
        if isNew { rebuildIndex() }
    }

    public mutating func remove(subtreeOf id: UUID) -> [UUID] {
        var removed: [UUID] = []
        var stack = [id]
        while let next = stack.popLast() {
            removed.append(next)
            stack.append(contentsOf: childrenByParent[next] ?? [])
        }
        for id in removed { messages[id] = nil }
        rebuildIndex()
        return removed
    }

    public func children(of id: UUID?) -> [Message] {
        (childrenByParent[id] ?? []).compactMap { messages[$0] }
    }

    public func siblings(of id: UUID) -> [Message] {
        guard let message = messages[id] else { return [] }
        return children(of: message.parentID)
    }

    /// Position of a message among its siblings, for the ‹ 2/3 › control.
    public func branchPosition(of id: UUID) -> (index: Int, count: Int) {
        let siblings = siblings(of: id)
        let index = siblings.firstIndex { $0.id == id } ?? 0
        return (index, max(siblings.count, 1))
    }

    /// Follows the newest child from `id` down to a leaf.
    public func latestLeaf(from id: UUID?) -> UUID? {
        var current = id
        while let next = childrenByParent[current]?.last {
            current = next
        }
        return current
    }

    /// Root-to-leaf path ending at `leaf`. Falls back to the newest leaf if `leaf` is unknown.
    public func path(to leaf: UUID?) -> [Message] {
        var tip = leaf.flatMap { messages[$0] != nil ? $0 : nil } ?? latestLeaf(from: nil)
        var path: [Message] = []
        var guardCount = 0
        while let id = tip, let message = messages[id], guardCount <= messages.count {
            path.append(message)
            tip = message.parentID
            guardCount += 1
        }
        return path.reversed()
    }

    /// Leaf to show after switching to the sibling at `offset` (-1 previous, +1 next) of `id`.
    public func leafAfterSwitching(from id: UUID, offset: Int) -> UUID? {
        let siblings = siblings(of: id)
        guard let index = siblings.firstIndex(where: { $0.id == id }) else { return nil }
        let target = index + offset
        guard siblings.indices.contains(target) else { return nil }
        return latestLeaf(from: siblings[target].id)
    }

    public var allMessages: [Message] {
        messages.values.sorted { $0.createdAt < $1.createdAt }
    }
}
