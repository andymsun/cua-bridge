import Foundation
import Darwin

@main struct DraftChecks {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }
    static func wait<T>(_ operation: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        operation { result = $0; done.signal() }
        precondition(done.wait(timeout: .now() + 5) == .success, "draft I/O must complete")
        return try result!.get()
    }
    static func rejected(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("the draft change must fail without replacing saved text") }
        catch { checks += 1 }
    }
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("draft-check-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }
        func directory(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return url
        }
        func load(_ store: CompanionDrafts) throws -> [String: CompanionDraft] { try wait { store.load(completion: $0) } }
        func save(_ store: CompanionDrafts, _ id: String, _ text: String, _ revision: Int) throws { try wait { store.save(id: id, text: text, revision: revision, completion: $0) } }
        func forget(_ store: CompanionDrafts, _ id: String) throws { try wait { store.forget(id: id, completion: $0) } }
        func flush(_ store: CompanionDrafts) throws { try wait { store.flush(completion: $0) } }

        let root = try directory("normal"), store = CompanionDrafts(directory: root)
        check(try load(store).isEmpty, "an empty store starts without a draft")
        let first = "  Keep spaces\n日本語 ☕\n", second = "Keep another conversation"
        try save(store, "session-a", first, 10); try save(store, "session-b", second, 20)
        let restored = try load(CompanionDrafts(directory: root))
        check(restored["session-a"]?.text == first && restored["session-b"]?.text == second, "restart restores exact separate drafts")
        check(restored["session-a"]?.revision == 10, "the saved revision survives restart")
        let file = root.appendingPathComponent("companion-drafts.json")
        let attrs = try fm.attributesOfItem(atPath: file.path)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "saved drafts are private")

        try save(store, "session-a", "New text after Submit", 11)
        try save(store, "session-a", "", 10)
        check(try load(CompanionDrafts(directory: root))["session-a"]?.text == "New text after Submit", "a late submit acknowledgment cannot delete newer text")
        rejected { try save(store, "session-a", "Different text with the same revision", 11) }
        try save(store, "session-a", "", 12)
        check(try load(CompanionDrafts(directory: root))["session-a"]?.text == "", "an acknowledged current send clears only its own draft")
        try save(store, "session-a", first, 11)
        check(try load(store)["session-a"]?.text == "", "a cleared draft keeps a revision tombstone")
        try forget(store, "session-a")
        try save(store, "session-a", "Late deleted-conversation callback", 13)
        check(try load(store)["session-a"] == nil, "confirmed deletion rejects late callbacks in this app lifetime")
        check(try load(store)["session-b"]?.text == second, "deletion preserves the other conversation")
        try flush(store)

        let before = try Data(contentsOf: file)
        for (id, text, revision) in [("bad/id", "x", 1), ("session-b", String(repeating: "x", count: 8001), 21), ("session-b", "x", -1)] {
            rejected { try save(store, id, text, revision) }
        }
        check(try Data(contentsOf: file) == before, "invalid data cannot change the file")
        try save(store, "session-b", second, 22)
        for n in 1...15 { try save(store, "draft-\(n)", "Draft \(n)", n) }
        rejected { try save(store, "overflow", "Never evict an unsent draft", 1) }
        check(try load(store)["session-b"]?.text == second, "capacity errors never evict saved work")
        rejected { try save(store, "session-b", second + " updated", 23) }
        check(try load(CompanionDrafts(directory: root))["session-b"]?.text == second + " updated", "one draft can save while another failure remains visible")
        rejected { try flush(store) }
        try forget(store, "overflow"); try flush(store)

        let badRoot = try directory("corrupt"), badFile = badRoot.appendingPathComponent("companion-drafts.json")
        let corrupt = Data("not a draft document".utf8)
        try corrupt.write(to: badFile); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: badFile.path)
        let badStore = CompanionDrafts(directory: badRoot)
        rejected { _ = try load(badStore) }
        rejected { try save(badStore, "new", "Do not replace unreadable data", 1) }
        check(try Data(contentsOf: badFile) == corrupt, "corrupt data is preserved for recovery")
        rejected { try flush(badStore) }

        let changedRoot = try directory("external"), changedStore = CompanionDrafts(directory: changedRoot)
        _ = try load(changedStore); try save(changedStore, "a", "Original", 1)
        let changedFile = changedRoot.appendingPathComponent("companion-drafts.json"), external = Data("external change".utf8)
        try external.write(to: changedFile)
        rejected { try save(changedStore, "a", "Local text", 2) }
        check(try Data(contentsOf: changedFile) == external, "an external file change is not overwritten")

        let linkRoot = try directory("symlink"), sentinel = base.appendingPathComponent("sentinel.json")
        try Data("Keep this unrelated file".utf8).write(to: sentinel)
        try fm.createSymbolicLink(at: linkRoot.appendingPathComponent("companion-drafts.json"), withDestinationURL: sentinel)
        let linkStore = CompanionDrafts(directory: linkRoot)
        rejected { _ = try load(linkStore) }
        rejected { try save(linkStore, "a", "No symlink write", 1) }
        check(try String(contentsOf: sentinel, encoding: .utf8) == "Keep this unrelated file", "a symlink never changes its destination")

        let deniedRoot = try directory("write-error"), deniedStore = CompanionDrafts(directory: deniedRoot)
        _ = try load(deniedStore); try save(deniedStore, "a", "Saved", 1)
        let deniedFile = deniedRoot.appendingPathComponent("companion-drafts.json"), saved = try Data(contentsOf: deniedFile)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: deniedRoot.path)
        rejected { try save(deniedStore, "a", "Unsaved but still in memory", 2) }
        rejected { try flush(deniedStore) }
        rejected { try save(deniedStore, "a", "Saved", 1) }
        check(try Data(contentsOf: deniedFile) == saved, "failed replacement leaves the old valid document")
        check(try load(deniedStore)["a"]?.text == "Unsaved but still in memory", "a page reload keeps unsaved in-memory text")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedRoot.path)
        try save(deniedStore, "a", "Unsaved but still in memory", 3); try flush(deniedStore)
        check(try load(CompanionDrafts(directory: deniedRoot))["a"]?.text == "Unsaved but still in memory", "a later successful save clears the write failure")
        let leftovers = try fm.contentsOfDirectory(atPath: deniedRoot.path)
        check(leftovers == ["companion-drafts.json"], "atomic writes leave no temporary draft copies")
        print("PASS \(checks) native draft persistence, revision, privacy, recovery, and atomic-write checks")
    }
}
