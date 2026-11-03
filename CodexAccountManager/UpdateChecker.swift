import Foundation

enum UpdateCheckFailure: Equatable {
    case network, rateLimited, invalidResponse
}

enum UpdateCheckStatus: Equatable {
    case idle, checking, upToDate, available(String), noRelease, failed(UpdateCheckFailure)
}

struct ReleaseVersion: Comparable {
    let display: String
    private let components: [Int]

    init?(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        guard !value.isEmpty, value.utf8.count <= 40 else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.count <= 9 && part.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        var numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        while numbers.count > 1 && numbers.last == 0 { numbers.removeLast() }
        self.display = value
        self.components = numbers
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.components == rhs.components }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

struct GitHubUpdateChecker {
    static let latestReleaseURL = URL(string: "https://github.com/StarRain/Codex-Account-Manager/releases/latest")!
    static let apiURL = URL(string: "https://api.github.com/repos/StarRain/Codex-Account-Manager/releases/latest")!

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    func check(currentVersion: String, completion: @escaping (UpdateCheckStatus) -> Void) {
        var request = URLRequest(url: Self.apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Account-Manager", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            completion(Self.result(currentVersion: currentVersion, data: data, response: response, error: error))
        }.resume()
    }

    static func result(currentVersion: String, data: Data?, response: URLResponse?, error: Error?) -> UpdateCheckStatus {
        guard error == nil, let response = response as? HTTPURLResponse else { return .failed(.network) }
        switch response.statusCode {
        case 404: return .noRelease
        case 403, 429: return .failed(.rateLimited)
        case 200: break
        default: return .failed(.network)
        }
        struct Release: Decodable {
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
        }
        guard let data, data.count <= 1_048_576,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease,
              let remote = ReleaseVersion(release.tag_name), let current = ReleaseVersion(currentVersion) else {
            return .failed(.invalidResponse)
        }
        return current < remote ? .available(remote.display) : .upToDate
    }
}
