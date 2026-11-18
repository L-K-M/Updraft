import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The download operation the updater needs, so tests can stub the network.
public protocol UpdateDownloadSession: Sendable {
    func downloadAsset(from url: URL) async throws -> (URL, URLResponse)
}

extension URLSession: UpdateDownloadSession {
    public func downloadAsset(from url: URL) async throws -> (URL, URLResponse) {
        try await download(from: url)
    }
}
