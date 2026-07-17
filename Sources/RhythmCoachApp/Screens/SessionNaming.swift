import Foundation

/// Display-time numbering of sessions that share a name ("Warmup 1",
/// "Warmup 2"). Never stored — deleting a session renumbers the rest.
enum SessionNaming {
    /// id → display title. Groups by exact trimmed name; groups of two or
    /// more get " 1", " 2", … appended in chronological order (startedAt
    /// ascending, ties broken by id). Unnamed sessions get no entry —
    /// callers fall back to the date.
    static func displayNames(for sessions: [SessionRecord]) -> [SessionRecord.ID: String] {
        var groups: [String: [SessionRecord]] = [:]
        for session in sessions {
            guard let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            groups[name, default: []].append(session)
        }
        var result: [SessionRecord.ID: String] = [:]
        for (name, group) in groups {
            guard group.count > 1 else {
                result[group[0].id] = name
                continue
            }
            let ordered = group.sorted {
                ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
            }
            for (index, session) in ordered.enumerated() {
                result[session.id] = "\(name) \(index + 1)"
            }
        }
        return result
    }
}
