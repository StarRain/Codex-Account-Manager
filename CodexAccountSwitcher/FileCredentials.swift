import CryptoKit
import Darwin
import Foundation

/// The credential bytes are never included in profile metadata or logs.
struct CredentialSnapshot {
    let kind: ProfileKind
    let fingerprint: String
    let bytes: Data
    let email: String?
    let displayName: String?
    let accountPlanType: String?
    let chatgptAccountID: String?

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(bytes: Data) throws {
        guard bytes.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw CodexError.invalidCredentials }
        let key = object["OPENAI_API_KEY"] as? String
        let tokens = object["tokens"] as? [String: Any]
        if let key, !key.isEmpty, tokens == nil {
            kind = .openai
            fingerprint = Self.fingerprint("api\0" + key)
            email = nil
            displayName = nil
            accountPlanType = nil
            chatgptAccountID = nil
        } else if (key == nil || key == ""), let tokens,
                  let idToken = tokens["id_token"] as? String,
                  let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty,
                  let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
                  let accountID = tokens["account_id"] as? String, !accountID.isEmpty,
                  let claims = Self.jwtClaims(idToken), let subject = claims["sub"] as? String, !subject.isEmpty {
            kind = .chatgpt
            fingerprint = Self.fingerprint("chatgpt\0" + subject + "\0" + accountID)
            email = claims["email"] as? String
            let name = (claims["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            displayName = name.flatMap {
                !$0.isEmpty && $0.count <= 120 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? $0 : nil
            }
            chatgptAccountID = accountID
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            // A token may describe a different workspace; never apply its
            // subscription to the selected account unless the IDs match.
            accountPlanType = auth?["chatgpt_account_id"] as? String == accountID
                ? ChatGPTPlan.knownValue(auth?["chatgpt_plan_type"] as? String) : nil
        } else { throw CodexError.invalidCredentials }
        self.bytes = bytes
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload), bytes.count <= 65_536 else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
}

struct FileCredentials {
    let home: URL
    var file: URL { home.appendingPathComponent("auth.json") }

    func raw() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1_048_576 else { throw CodexError.invalidCredentials }
        return try Data(contentsOf: file)
    }

    func read() throws -> CredentialSnapshot? {
        guard let bytes = try raw() else { return nil }
        return try CredentialSnapshot(bytes: bytes)
    }

    /// Compare the live file twice, write privately, then atomically replace it.
    /// A concurrent writer after the rename cannot be coordinated by this API;
    /// running Codex clients must be closed when switching saved accounts.
    func replace(expected: Data?, with bytes: Data) throws {
        _ = try CredentialSnapshot(bytes: bytes)
        guard try raw() == expected else { throw CodexError.changedExternally }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = home.appendingPathComponent(".codex-switcher-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CodexError.requestFailed }
        var closed = false
        defer { if !closed { _ = close(fd) }; _ = unlink(temporary.path) }
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw CodexError.invalidCredentials }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw CodexError.requestFailed }
                offset += written
            }
        }
        guard fsync(fd) == 0, close(fd) == 0 else { throw CodexError.requestFailed }
        closed = true
        guard try raw() == expected else { throw CodexError.changedExternally }
        guard rename(temporary.path, file.path) == 0 else { throw CodexError.requestFailed }
    }
}
