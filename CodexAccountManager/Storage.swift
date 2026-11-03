import Foundation
import Darwin

enum StoreError: LocalizedError {
    case missingSecret
    case invalidSecret
    case invalidDirectory
    case destinationHasProfiles
    case destinationHasCredentials
    case credentialFile
    var errorDescription: String? {
        switch self {
        case .missingSecret: return L("未找到此配置的密钥，请重新保存。")
        case .invalidSecret: return L("保存的密钥无法读取，请重新保存。")
        case .invalidDirectory: return L("请输入有效的绝对目录路径。")
        case .destinationHasProfiles: return L("目标目录已有不同的配置，请选择空目录，避免覆盖。")
        case .destinationHasCredentials: return L("目标目录已有不同的凭据文件，请选择其他目录，避免覆盖。")
        case .credentialFile: return L("无法安全读写凭据文件，请检查应用配置目录的权限。")
        }
    }
}

struct ProfileStore {
    static let preferenceKey = "camProfileDirectory"
    let directory: URL
    var file: URL { directory.appendingPathComponent("profiles.json") }

    static func standard() -> ProfileStore {
        ProfileStore(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cam", isDirectory: true))
    }

    func load() throws -> [CodexProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([CodexProfile].self, from: Data(contentsOf: file))
    }

    func save(_ profiles: [CodexProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Copy metadata without removing the original or replacing another
    /// directory's profiles. Credential files are copied separately.
    func copyProfiles(to directory: URL, profiles: [CodexProfile]) throws -> ProfileStore {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw StoreError.invalidDirectory }
        let target = ProfileStore(directory: directory.standardizedFileURL)
        if target.directory.resolvingSymlinksInPath().path == self.directory.standardizedFileURL.resolvingSymlinksInPath().path { return self }
        try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let targetExists = FileManager.default.fileExists(atPath: target.file.path)
        if targetExists {
            guard (try? target.load()) == profiles else { throw StoreError.destinationHasProfiles }
        }
        try SavedCredentialFiles(root: self.directory).copy(to: SavedCredentialFiles(root: target.directory), ids: profiles.map(\.id))
        if targetExists {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.file.path)
        } else {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { try encoder.encode(profiles).write(to: target.file, options: .withoutOverwriting) }
            catch {
                if FileManager.default.fileExists(atPath: target.file.path) { throw StoreError.destinationHasProfiles }
                throw error
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.file.path)
        }
        return target
    }
}

protocol CredentialStoring {
    func save(_ secret: String, id: UUID) throws
    func load(id: UUID) throws -> String
    func delete(id: UUID) throws
}

/// One private Codex-format JSON file per saved profile. ChatGPT files retain
/// the original auth.json bytes; API keys use Codex's OPENAI_API_KEY field.
struct SavedCredentialFiles: CredentialStoring {
    let root: URL
    var directory: URL { root.appendingPathComponent("credentials", isDirectory: true) }
    private let sizeLimit = 1_048_576

    private func filename(_ id: UUID) -> String { id.uuidString.lowercased() + ".json" }

    private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw StoreError.credentialFile }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw StoreError.credentialFile }
        defer { _ = close(directoryFD) }
        var directoryStat = stat()
        guard fstat(directoryFD, &directoryStat) == 0,
              directoryStat.st_mode & S_IFMT == S_IFDIR, directoryStat.st_uid == getuid(),
              fchmod(directoryFD, 0o700) == 0 else { throw StoreError.credentialFile }

        let lockFD = openat(directoryFD, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw StoreError.credentialFile }
        defer { _ = close(lockFD) }
        var lockStat = stat()
        guard fstat(lockFD, &lockStat) == 0, lockStat.st_mode & S_IFMT == S_IFREG,
              lockStat.st_uid == getuid(), lockStat.st_nlink == 1, fchmod(lockFD, 0o600) == 0 else { throw StoreError.credentialFile }
        while flock(lockFD, LOCK_EX) != 0 {
            if errno != EINTR { throw StoreError.credentialFile }
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        return try body(directoryFD)
    }

    private func read(_ name: String, from directoryFD: Int32) throws -> Data? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw StoreError.credentialFile }
        defer { _ = close(fd) }
        var details = stat()
        guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
              details.st_uid == getuid(), details.st_nlink == 1, details.st_size >= 0,
              details.st_size <= sizeLimit, fchmod(fd, 0o600) == 0 else { throw StoreError.credentialFile }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw StoreError.credentialFile
            }
            guard result.count + count <= sizeLimit else { throw StoreError.invalidSecret }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func write(_ data: Data, name: String, in directoryFD: Int32, overwrite: Bool) throws {
        guard !data.isEmpty, data.count <= sizeLimit else { throw StoreError.invalidSecret }
        // Refuse to follow or replace an unexpected symlink or non-regular file.
        let existing = try read(name, from: directoryFD)
        if !overwrite, existing != nil { throw StoreError.destinationHasCredentials }
        let temporary = ".tmp-" + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.credentialFile }
        var closed = false
        defer { if !closed { _ = close(fd) }; _ = unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw StoreError.invalidSecret }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.credentialFile }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw StoreError.credentialFile }
        let closeResult = close(fd)
        closed = true
        guard closeResult == 0 else { throw StoreError.credentialFile }
        if overwrite {
            guard renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw StoreError.credentialFile }
        } else {
            guard linkat(directoryFD, temporary, directoryFD, name, 0) == 0 else {
                throw errno == EEXIST ? StoreError.destinationHasCredentials : StoreError.credentialFile
            }
        }
    }

    private func encoded(_ secret: String) throws -> Data {
        guard !secret.isEmpty else { throw StoreError.invalidSecret }
        let data = Data(secret.utf8)
        if let snapshot = try? CredentialSnapshot(bytes: data), snapshot.kind == .chatgpt { return data }
        return try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": secret], options: [.sortedKeys])
    }

    private func decoded(_ data: Data) throws -> String {
        guard let snapshot = try? CredentialSnapshot(bytes: data) else { throw StoreError.invalidSecret }
        if snapshot.kind == .chatgpt {
            guard let value = String(data: data, encoding: .utf8) else { throw StoreError.invalidSecret }
            return value
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty else { throw StoreError.invalidSecret }
        return key
    }

    func save(_ secret: String, id: UUID) throws {
        let data = try encoded(secret)
        try withDirectory { try write(data, name: filename(id), in: $0, overwrite: true) }
    }

    func load(id: UUID) throws -> String {
        try withDirectory { directoryFD in
            guard let data = try read(filename(id), from: directoryFD) else { throw StoreError.missingSecret }
            return try decoded(data)
        }
    }

    func loadAPIKey(id: UUID) throws -> String {
        try withDirectory { directoryFD in
            guard let data = try read(filename(id), from: directoryFD) else { throw StoreError.missingSecret }
            guard let snapshot = try? CredentialSnapshot(bytes: data), snapshot.kind == .openai,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty else { throw StoreError.invalidSecret }
            return key
        }
    }

    func delete(id: UUID) throws {
        try withDirectory { directoryFD in
            let name = filename(id)
            guard try read(name, from: directoryFD) != nil else { return }
            guard unlinkat(directoryFD, name, 0) == 0 else { throw StoreError.credentialFile }
        }
    }

    private func snapshot(ids: [UUID]) throws -> [UUID: Data] {
        guard !ids.isEmpty else { return [:] }
        return try withDirectory { directoryFD in
            var result: [UUID: Data] = [:]
            for id in ids {
                if let data = try read(filename(id), from: directoryFD) {
                    _ = try decoded(data)
                    result[id] = data
                }
            }
            return result
        }
    }

    /// Copy without overwriting conflicts; retain the original directory.
    func copy(to destination: SavedCredentialFiles, ids: [UUID]) throws {
        guard root.standardizedFileURL.resolvingSymlinksInPath().path != destination.root.standardizedFileURL.resolvingSymlinksInPath().path,
              !ids.isEmpty else { return }
        let source = try snapshot(ids: ids)
        try destination.withDirectory { directoryFD in
            for id in ids {
                let existing = try destination.read(destination.filename(id), from: directoryFD)
                if let existing, existing != source[id] { throw StoreError.destinationHasCredentials }
            }
            for id in ids {
                guard let data = source[id], try destination.read(destination.filename(id), from: directoryFD) == nil else { continue }
                try destination.write(data, name: destination.filename(id), in: directoryFD, overwrite: false)
            }
        }
        guard try snapshot(ids: ids) == source else { throw StoreError.credentialFile }
    }
}
