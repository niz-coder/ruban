import Foundation
import RubanCore

/// Saves column order, widths and stacks so the layout comes back after a restart.
/// Windows have no stable identity across launches, so they are matched by app and title.
final class SessionStore {
    struct Item: Codable { var bundleID: String; var title: String }
    struct SavedColumn: Codable {
        var items: [Item]
        var width: Double
        var tabbed: Bool
        var pinned: PinSide?
    }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ruban", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }()

    private var saved: [String: [SavedColumn]]

    init() {
        saved = (try? JSONDecoder().decode([String: [SavedColumn]].self, from: Data(contentsOf: url))) ?? [:]
    }

    /// Records these strips, keeping the ones saved for other displays and Spaces, and writes them out.
    func save(_ strips: [String: [SavedColumn]]) {
        for (k, v) in strips { saved[k] = v }
        do {
            try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        } catch {
            Log.write("session: could not save the column order: \(error.localizedDescription)")
        }
    }

    /// The saved strip for a key, falling back to any strip saved for the same display
    /// (Space ids can change across restarts).
    func columns(for key: String) -> [SavedColumn] {
        if let exact = saved[key] { return exact }
        let display = key.split(separator: "#").first.map(String.init) ?? key
        return saved.first { $0.key.hasPrefix(display + "#") }?.value ?? []
    }

    /// Orders new windows the way they were saved. Returns the columns to build, in order;
    /// windows that match nothing come last, in their on-screen order.
    func restore(_ windows: [(id: WindowID, bundleID: String, title: String)], key: String, defaultWidth: (WindowID) -> Double) -> [Column] {
        let saved = columns(for: key)
        var assigned: [WindowID: (Int, Int)] = [:]
        var used = Set<WindowID>()
        // Exact title matches first, then same app in order.
        for exact in [true, false] {
            for (ci, col) in saved.enumerated() {
                for (ii, item) in col.items.enumerated() where !assigned.values.contains(where: { $0 == (ci, ii) }) {
                    guard let w = windows.first(where: {
                        !used.contains($0.id) && $0.bundleID == item.bundleID && (!exact || $0.title == item.title)
                    }) else { continue }
                    used.insert(w.id)
                    assigned[w.id] = (ci, ii)
                }
            }
        }
        var result: [Column] = []
        for (ci, col) in saved.enumerated() {
            let members = windows.filter { assigned[$0.id]?.0 == ci }.sorted { assigned[$0.id]!.1 < assigned[$1.id]!.1 }
            guard let first = members.first else { continue }
            var c = Column(window: first.id, width: col.width)
            for m in members.dropFirst() {
                c.windows.append(m.id)
                c.weights.append(1)
            }
            c.tabbed = col.tabbed && c.windows.count > 1
            c.pinned = col.pinned
            result.append(c)
        }
        for w in windows where !used.contains(w.id) {
            result.append(Column(window: w.id, width: defaultWidth(w.id)))
        }
        return result
    }
}
