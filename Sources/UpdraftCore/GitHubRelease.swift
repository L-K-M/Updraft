import Foundation

/// The subset of GitHub's Releases API we care about.
/// See <https://docs.github.com/en/rest/releases/releases>.
///
/// Reusable across apps — depends only on Foundation.
public struct GitHubRelease: Decodable, Sendable {

    /// One downloadable file attached to a release.
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let contentType: String
        public let size: Int
        public let browserDownloadURL: URL
        /// GitHub's content digest, e.g. "sha256:…" (absent on very old API responses).
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case contentType = "content_type"
            case size
            case browserDownloadURL = "browser_download_url"
            case digest
        }

        public init(name: String, contentType: String, size: Int,
                    browserDownloadURL: URL, digest: String? = nil) {
            self.name = name
            self.contentType = contentType
            self.size = size
            self.browserDownloadURL = browserDownloadURL
            self.digest = digest
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            contentType = try c.decode(String.self, forKey: .contentType)
            size = try c.decode(Int.self, forKey: .size)
            browserDownloadURL = try c.decode(URL.self, forKey: .browserDownloadURL)
            digest = try c.decodeIfPresent(String.self, forKey: .digest)
        }
    }

    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let prerelease: Bool
    public let draft: Bool
    public let publishedAt: Date?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case htmlURL = "html_url"
        case prerelease, draft
        case publishedAt = "published_at"
        case assets
    }

    /// Self-contained decode: `published_at` arrives as an ISO 8601 string,
    /// which the default `.deferredToDate` strategy would reject — and the key
    /// being present means a thrown `typeMismatch`, not a nil. Parsing the
    /// string here keeps the type correct under any decoder configuration,
    /// which a reusable type can't outsource to its call sites.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        htmlURL = try c.decode(URL.self, forKey: .htmlURL)
        prerelease = try c.decode(Bool.self, forKey: .prerelease)
        draft = try c.decode(Bool.self, forKey: .draft)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
            .flatMap(Self.parseDate)
        assets = try c.decode([Asset].self, forKey: .assets)
    }

    /// The best asset for this machine under the default selection rules.
    public var preferredAsset: Asset? { preferredAsset(using: .default) }

    /// The best asset for this machine under `selection`.
    public func preferredAsset(using selection: AssetSelection) -> Asset? {
        selection.preferredAsset(in: self)
    }

    /// A trimmed, length-capped form of the release body, suitable for an alert's
    /// informative text (markdown is shown as-is — GitHub bodies are mostly plain).
    /// `maxLength` bounds the returned string — the ellipsis counts against it.
    public func releaseNotes(maxLength: Int = 600) -> String? {
        guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        guard body.count > maxLength else { return body }
        // An ellipsis alone is 1 char — below maxLength 2 nothing fits.
        guard maxLength > 1 else { return nil }
        let end = body.index(body.startIndex, offsetBy: maxLength - 1)
        return String(body[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Parses `published_at`: fractional seconds first, plain second. The
    /// formatters are created per call — `ISO8601DateFormatter` is not
    /// thread-safe on every Foundation, and a release page decodes many dates.
    private static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
