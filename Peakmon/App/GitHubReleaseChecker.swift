import Foundation

/// GitHub metadata is used for version discovery and browser links only.
/// Sparkle still validates signed feeds and archives before installing anything.
struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let state: String
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name, body, draft, prerelease, assets
    }

    var hasUpdateFeed: Bool {
        assets.contains { $0.name == "appcast.xml" && $0.state == "uploaded" }
    }

    func version() throws -> ReleaseVersion {
        // Peakmon's date tags are not semantic versions. Prefer the Build Info table.
        if let value = buildInfoValue("Version") {
            guard let version = ReleaseVersion(value) else { throw GitHubReleaseCheckError.invalidMetadata }
            return version
        }
        let title = name ?? ""
        let pattern = #"(?i)\bPeakmon\s+v?([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$"#
        if let range = title.range(of: pattern, options: .regularExpression) {
            let value = title[range].split(separator: " ").last.map(String.init) ?? ""
            if let version = ReleaseVersion(value) { return version }
        }
        if let version = ReleaseVersion(tagName) { return version }
        throw GitHubReleaseCheckError.invalidMetadata
    }

    func isNewer(than currentVersion: String, build currentBuild: String) throws -> Bool {
        guard let current = ReleaseVersion(currentVersion) else { throw GitHubReleaseCheckError.invalidMetadata }
        let latest = try version()
        if latest != current { return latest > current }
        guard let releaseBuild = buildInfoValue("Build") else { return false }
        guard Self.isBuildNumber(releaseBuild), Self.isBuildNumber(currentBuild) else {
            throw GitHubReleaseCheckError.invalidMetadata
        }
        return releaseBuild.compare(currentBuild, options: .numeric) == .orderedDescending
    }

    private func buildInfoValue(_ field: String) -> String? {
        for line in (body ?? "").components(separatedBy: .newlines) {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "")
            }
            if cells.count >= 4, cells[1].caseInsensitiveCompare(field) == .orderedSame {
                return cells[2]
            }
        }
        return nil
    }

    private static func isBuildNumber(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil
    }
}

struct ReleaseVersion: Comparable, Sendable {
    let displayString: String
    private let components: [Int]

    init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        guard normalized.range(of: #"^[0-9]+\.[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let components = normalized.split(separator: ".").compactMap { Int($0) }
        guard components.count == normalized.split(separator: ".").count else { return nil }
        displayString = normalized
        self.components = components + Array(repeating: 0, count: 3 - components.count)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.components == rhs.components }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

enum GitHubReleaseCheckError: Error {
    case responseStatus(Int)
    case invalidMetadata
}

enum GitHubReleaseChecker {
    static func latest(session: URLSession = .shared) async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/crafcat7/Peakmon/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Peakmon", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GitHubReleaseCheckError.invalidMetadata }
        guard response.statusCode == 200 else { throw GitHubReleaseCheckError.responseStatus(response.statusCode) }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease,
              release.htmlURL.scheme == "https", release.htmlURL.host == "github.com",
              release.htmlURL.path.hasPrefix("/crafcat7/Peakmon/releases/tag/")
        else { throw GitHubReleaseCheckError.invalidMetadata }
        _ = try release.version()
        return release
    }
}
