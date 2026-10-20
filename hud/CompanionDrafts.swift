import Foundation
import Darwin

struct CompanionDraft: Codable, Equatable {
    let text: String
    let revision: Int
}

final class CompanionDrafts {
    private struct Document: Codable {
        let version: Int
        let drafts: [String: CompanionDraft]
    }
    private let directory: URL, file: URL
    private let queue = DispatchQueue(label: "com.andymsun.cua.drafts", qos: .utility)
    private var drafts: [String: CompanionDraft] = [:]
    private var forgotten = Set<String>()
    private var loaded = false, dirty = false
    private var original: Data?
    private var loadError: Error?, saveError: Error?
    private var rejected: [String: (revision: Int, error: Error)] = [:]
    private let maxBytes = 1_048_576

    init(directory: URL) {
        self.directory = directory
        file = directory.appendingPathComponent("companion-drafts.json")
    }

    func load(completion: @escaping (Result<[String: CompanionDraft], Error>) -> Void) {
        queue.async {
            if self.loaded { completion(.success(self.drafts)); return }
            self.loaded = true
            do {
                let bytes = try self.readFile()
                if let bytes = bytes {
                    let document = try JSONDecoder().decode(Document.self, from: bytes)
                    guard document.version == 1, document.drafts.count <= 16 else { throw self.failure("Saved drafts have an unsupported format or exceed the limit.") }
                    for (id, draft) in document.drafts { try self.validate(id: id, draft: draft) }
                    self.drafts = document.drafts
                }
                self.original = bytes
                completion(.success(self.drafts))
            } catch { self.loadError = error; completion(.failure(error)) }
        }
    }

    func save(id: String, text: String, revision: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            var accepted = false
            do {
                guard self.loaded else { throw self.failure("Wait for saved drafts to load.") }
                let draft = CompanionDraft(text: text, revision: revision)
                try self.validate(id: id, draft: draft)
                if self.forgotten.contains(id) || revision < (self.rejected[id]?.revision ?? 0) { completion(self.savedResult()); return }
                if let current = self.drafts[id] {
                    if revision < current.revision { completion(self.savedResult()); return }
                    if revision == current.revision && text != current.text { throw self.failure("A stale draft update was rejected.") }
                } else if self.drafts.count >= 16 { throw self.failure("The saved draft limit was reached. Keep a copy of this draft before you close the app.") }
                self.rejected.removeValue(forKey: id); accepted = true
                if self.drafts[id] != draft || self.dirty {
                    self.drafts[id] = draft; self.dirty = true
                    try self.persist()
                }
                completion(self.savedResult())
            } catch {
                if !accepted, self.validID(id), revision >= (self.rejected[id]?.revision ?? 0) { self.rejected[id] = (revision, error) }
                self.saveError = error; completion(.failure(error))
            }
        }
    }

    func forget(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                guard self.loaded else { throw self.failure("Wait for saved drafts to load.") }
                try self.validate(id: id, draft: CompanionDraft(text: "", revision: 0))
                let removed = self.drafts.removeValue(forKey: id) != nil
                let rejected = self.rejected.removeValue(forKey: id) != nil
                guard removed || rejected else { completion(self.savedResult()); return }
                self.forgotten.insert(id)
                if removed { self.dirty = true; try self.persist() }
                completion(self.savedResult())
            } catch { self.dirty = true; self.saveError = error; completion(.failure(error)) }
        }
    }

    private func savedResult() -> Result<Void, Error> {
        if let error = loadError { return .failure(error) }
        if let failure = rejected.values.first { return .failure(failure.error) }
        if dirty { return .failure(saveError ?? failure("The current draft is not saved.")) }
        return .success(())
    }
    func flush(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            completion(self.dirty || !self.rejected.isEmpty ? self.savedResult() : .success(()))
        }
    }

    private func validID(_ id: String) -> Bool { id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil }
    private func validate(id: String, draft: CompanionDraft) throws {
        guard validID(id),
              draft.text.utf16.count <= 8000, draft.revision >= 0, draft.revision <= 9_007_199_254_740_991 else {
            throw failure("The draft ID, text, or revision is invalid.")
        }
    }
    private func failure(_ message: String) -> Error {
        NSError(domain: "CUACompanionDrafts", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func systemError() -> Error { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private func checkDirectory() throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw systemError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw failure("The draft directory must be a private directory owned by this user.")
        }
    }
    private func readFile() throws -> Data? {
        try checkDirectory()
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw systemError()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw systemError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= maxBytes else {
            throw failure("Saved drafts must be a private regular file no larger than 1 MiB.")
        }
        let bytes = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard bytes.count <= maxBytes else { throw failure("Saved drafts exceed the size limit.") }
        return bytes
    }
    private func persist() throws {
        do {
            if let error = loadError { throw error }
            guard try readFile() == original else {
                let error = failure("The saved draft file changed outside this app. It was not overwritten.")
                loadError = error; throw error
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(Document(version: 1, drafts: drafts))
            guard bytes.count <= maxBytes else { throw failure("Saved drafts exceed the size limit.") }
            let temporary = directory.appendingPathComponent(".companion-drafts-" + UUID().uuidString + ".tmp")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw systemError() }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); unlink(temporary.path) }
            try handle.write(contentsOf: bytes); try handle.synchronize()
            guard rename(temporary.path, file.path) == 0 else { throw systemError() }
            original = bytes; dirty = false; saveError = nil
        } catch { saveError = error; throw error }
    }
}
