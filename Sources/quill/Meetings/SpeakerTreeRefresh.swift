import Foundation

/// Rediscover the current meeting tree in small chunks. A large chat or a
/// changed layout must not make each poll restart before reaching new tiles.
struct SpeakerTreeRefresh<Element: Hashable> {
    struct Entry {
        let element: Element
        let node: SpeakerUINode
    }

    private var root: Element?
    private var queue: [(Element, Int?)] = []
    private var cursor = 0
    private var visited: Set<Element> = []
    private var entries: [Entry] = []
    private var startedAt = 0.0
    private var nextRefresh = 0.0
    private(set) var completedAt: Double?

    mutating func invalidate() {
        queue = []
        entries = []
        visited = []
        cursor = 0
        nextRefresh = 0
        completedAt = nil
    }

    func isFresh(at now: Double) -> Bool {
        completedAt.map { now - $0 < 15 } ?? false
    }

    /// Only a complete tree can replace the cache. Partial trees may hide a
    /// second label or speaker and must never authorize a name assignment.
    mutating func step(root: Element, now: Double, hasTime: () -> Bool,
                       read: (Element, Int?) -> (SpeakerUINode, [Element])?) -> [Entry]? {
        if self.root != root {
            invalidate()
            self.root = root
        }
        if queue.isEmpty {
            guard now >= nextRefresh else { return nil }
            startedAt = now
            queue = [(root, nil)]
        }
        guard now - startedAt < 60 else {
            invalidate()
            nextRefresh = now + 0.5
            return nil
        }
        var readCount = 0
        while cursor < queue.count, readCount < 256, hasTime() {
            let (element, parent) = queue[cursor]
            cursor += 1
            guard visited.insert(element).inserted else { continue }
            guard entries.count < 10000, let (node, children) = read(element, parent),
                  queue.count + children.count <= 20000 else {
                invalidate()
                nextRefresh = now + 0.5
                return nil
            }
            let index = entries.count
            entries.append(Entry(element: element, node: node))
            queue.append(contentsOf: children.map { ($0, index) })
            readCount += 1
        }
        guard cursor == queue.count else { return nil }
        let result = entries
        queue = []
        entries = []
        visited = []
        cursor = 0
        completedAt = now
        nextRefresh = now + 2
        return result
    }
}
