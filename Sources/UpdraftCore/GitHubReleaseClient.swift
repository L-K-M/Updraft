import Foundation
#if canImport(FoundationNetworking)
// Linux splits URLSession out of Foundation into its own module.
import FoundationNetworking
#endif

/// Fetches releases for a GitHub repository over the public REST API (no token —
/// unauthenticated requests are rate-limited to 60/hour per IP, ample for a
/// once-a-day check, but shared with everything else on the network, so a
/// limit answer is reported as `ClientError.rateLimited`).
///
/// Reusable across apps — depends only on Foundation.
public struct GitHubReleaseClient: ReleaseFetching {

    /// Sends one request. A seam so tests can answer without the network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Releases requested per page by the prerelease scan: GitHub's maximum.
    static let releasesPerPage = 100
    /// The most pages the prerelease scan reads, so 1,000 releases. Each page
    /// is one request against the unauthenticated limit of 60 an hour, and a
    /// repository with more releases than this is not one these apps check.
    static let maximumReleasePages = 10

    let owner: String
    let repo: String
    let userAgent: String?
    private let transport: Transport

    public enum ClientError: LocalizedError {
        case badResponse(Int)
        case noReleases
        case invalidURL
        /// GitHub refused the request because this network used up its
        /// unauthenticated allowance. `resetsAt` is when GitHub says to try
        /// again, if it said.
        case rateLimited(resetsAt: Date?)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "GitHub returned HTTP \(code)."
            case .noReleases:
                return "No published releases were found (the repository may have moved or gone private)."
            case .invalidURL: return "Couldn't form a valid GitHub API URL."
            case .rateLimited(let resetsAt):
                let limited = "GitHub is limiting requests from this network."
                guard let resetsAt else { return limited + " Try again later." }
                return limited + " Try again after \(Self.displayed(resetsAt))."
            }
        }

        /// The time alone when the reset is today (the usual case: GitHub's
        /// window is an hour), otherwise date and time.
        private static func displayed(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
            return formatter.string(from: date)
        }
    }

    public init(owner: String, repo: String, userAgent: String? = nil,
                session: URLSession = .shared) {
        self.init(owner: owner, repo: repo, userAgent: userAgent,
                  transport: { try await session.data(for: $0) })
    }

    init(owner: String, repo: String, userAgent: String?, transport: @escaping Transport) {
        self.owner = owner
        self.repo = repo
        self.userAgent = userAgent
        self.transport = transport
    }

    /// The newest published release. When `includePrereleases` is false this uses the
    /// repo's `releases/latest` endpoint (which already excludes drafts and
    /// pre-releases); otherwise it scans the releases and returns the
    /// highest-versioned non-draft one.
    public func latestRelease(includePrereleases: Bool) async throws -> GitHubRelease {
        if includePrereleases {
            guard let newest = Self.newestParseableRelease(try await allReleases()) else {
                throw ClientError.noReleases
            }
            return newest
        }
        return try await fetch(GitHubRelease.self, path: "releases/latest")
    }

    /// Every release, page by page. GitHub lists releases by creation date,
    /// not version, so a higher-versioned release can sit on a later page (a
    /// backported fix tagged after a newer prerelease, say). Reading stops at
    /// the first short page or after `maximumReleasePages`.
    private func allReleases() async throws -> [GitHubRelease] {
        var releases: [GitHubRelease] = []
        for page in 1...Self.maximumReleasePages {
            let batch = try await fetch([GitHubRelease].self,
                                        path: "releases?per_page=\(Self.releasesPerPage)&page=\(page)")
            releases += batch
            if batch.count < Self.releasesPerPage { break }
        }
        return releases
    }

    /// The highest-versioned non-draft release whose tag parses. Unparsable
    /// tags ("nightly", "build-42") are excluded rather than ranked as 0.0.0 —
    /// an all-unparsable page returns nil so the caller throws `noReleases`
    /// instead of surfacing an arbitrary release.
    public static func newestParseableRelease(_ releases: [GitHubRelease]) -> GitHubRelease? {
        releases
            .filter { !$0.draft }
            .compactMap { release -> (GitHubRelease, SemanticVersion)? in
                SemanticVersion(release.tagName).map { (release, $0) }
            }
            .max { $0.1 < $1.1 }?.0
    }

    private func fetch<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        // A malformed owner/repo must throw, not crash — this type is
        // documented reusable and callers aren't guaranteed URL-safe.
        // Percent-encode each component to GitHub's naming alphabet so a
        // "?", "#" or "/" can't redirect the request to another path.
        var nameAllowed = CharacterSet.alphanumerics
        nameAllowed.insert(charactersIn: "-._")
        guard let encodedOwner = owner.addingPercentEncoding(withAllowedCharacters: nameAllowed),
              let encodedRepo = repo.addingPercentEncoding(withAllowedCharacters: nameAllowed),
              let url = URL(string: "https://api.github.com/repos/\(encodedOwner)/\(encodedRepo)/\(path)") else {
            throw ClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub requires a User-Agent header; use the app's bundle id.
        request.setValue(userAgent ?? Bundle.main.bundleIdentifier ?? "Updraft",
                         forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse(-1) }
        // A 404 on the latest endpoint means "no published release yet" — or
        // a missing/private repo, which GitHub reports identically. The list
        // endpoint answers 200 [] for "none yet", so its 404 is unambiguously
        // repo-level: report it as such.
        if http.statusCode == 404 {
            if path.hasSuffix("releases/latest") { throw ClientError.noReleases }
            throw ClientError.badResponse(404)
        }
        if let rateLimit = Self.rateLimitError(http) { throw rateLimit }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.badResponse(http.statusCode) }

        // GitHubRelease decodes published_at itself, so no date strategy
        // is needed here — the model can't be broken by decoder config.
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// GitHub's rate-limit answers, per its REST documentation: the primary
    /// limit is a 403 or 429 with `x-ratelimit-remaining: 0` and the reset
    /// time in `x-ratelimit-reset` (epoch seconds); secondary limits send
    /// `retry-after` (seconds). Any other 429 is a rate limit with no stated
    /// reset. Any other 403 (requests remaining, no `retry-after`) is not
    /// about the rate limit and stays an ordinary HTTP error.
    static func rateLimitError(_ response: HTTPURLResponse, now: Date = Date()) -> ClientError? {
        let status = response.statusCode
        guard status == 403 || status == 429 else { return nil }

        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }),
           retryAfter >= 0 {
            return .rateLimited(resetsAt: now.addingTimeInterval(retryAfter))
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?
            .trimmingCharacters(in: .whitespaces) == "0" {
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                .map { Date(timeIntervalSince1970: $0) }
            return .rateLimited(resetsAt: reset)
        }
        return status == 429 ? .rateLimited(resetsAt: nil) : nil
    }
}
