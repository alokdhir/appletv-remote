import AppKit
import Foundation
import AppleTVLogging

/// Fetches and caches app icons from the iTunes Search API.
///
/// Icons are stored as PNG files in ~/Library/Caches/com.adhir.appletv-remote/icons/<bundleID>.png.
/// The cache is considered stale after 12 hours; refresh is triggered at app launch and on a timer.
@MainActor
final class AppIconCache: ObservableObject {

    static let shared = AppIconCache()

    /// Fires when any icon is newly cached — consumers can observe to refresh UI.
    @Published var version: Int = 0

    private let cacheDir: URL
    private let session: URLSession
    private let stalenessInterval: TimeInterval = 12 * 60 * 60
    private var refreshTask: Task<Void, Never>?

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = base.appendingPathComponent("com.adhir.appletv-remote/icons", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Return the cached icon for a bundle ID, or nil if not yet fetched.
    func icon(for bundleID: String) -> NSImage? {
        let url = iconURL(for: bundleID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Fetch icons for any bundle IDs not already cached, then refresh stale ones.
    /// Cancels any in-flight refresh first.
    func refresh(bundleIDs: [String]) {
        refreshTask?.cancel()
        refreshTask = Task { await fetchIcons(bundleIDs: bundleIDs) }
    }

    /// Refresh only if the cache is older than the staleness interval.
    func refreshIfStale(bundleIDs: [String]) {
        guard isStale() else { return }
        refresh(bundleIDs: bundleIDs)
    }

    // MARK: - Private

    private func iconURL(for bundleID: String) -> URL {
        cacheDir.appendingPathComponent("\(bundleID).png")
    }

    private func isStale() -> Bool {
        // Check the mtime of any cached file; if none exist, consider stale.
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return true
        }
        guard let newest = contents.compactMap({ url -> Date? in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }).max() else { return true }
        return Date().timeIntervalSince(newest) > stalenessInterval
    }

    private func fetchIcons(bundleIDs: [String]) async {
        for bundleID in bundleIDs {
            guard !Task.isCancelled else { return }
            let dest = iconURL(for: bundleID)
            // Skip if cached and fresh.
            if let mtime = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               Date().timeIntervalSince(mtime) < stalenessInterval {
                continue
            }
            do {
                try await fetchIcon(bundleID: bundleID, to: dest)
                await MainActor.run { version += 1 }
                Log.app.report("AppIconCache: cached icon for \(bundleID)")
            } catch {
                if !Task.isCancelled {
                    Log.app.report("AppIconCache: failed to fetch icon for \(bundleID): \(error.localizedDescription)")
                }
            }
            // Respect iTunes API rate limit (~20 req/min).
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func fetchIcon(bundleID: String, to dest: URL) async throws {
        // iTunes lookup to get the artwork URL.
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "entity", value: "software"),
        ]
        guard let lookupURL = components.url else { return }

        let (data, _) = try await session.data(from: lookupURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              var artworkURLString = first["artworkUrl100"] as? String else {
            return
        }

        // Upscale to 200×200 by replacing the size token in the CDN URL.
        artworkURLString = artworkURLString.replacingOccurrences(of: "100x100bb", with: "200x200bb")

        guard let artworkURL = URL(string: artworkURLString) else { return }
        let (imageData, _) = try await session.data(from: artworkURL)

        // Convert to PNG and write to cache.
        guard let image = NSImage(data: imageData),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: dest)
    }
}
