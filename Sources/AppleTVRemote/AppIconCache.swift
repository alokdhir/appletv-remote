import AppKit
import Foundation
import AppleTVLogging

/// Fetches and caches app icons from the iTunes Search API.
///
/// Bundled icons (Resources/AppIcons/<bundleID>.png) are served directly from
/// the app bundle and are always authoritative — no copying into the cache dir.
/// Network-fetched icons are stored in ~/Library/Caches/…/icons/<bundleID>.png.
@MainActor
final class AppIconCache: ObservableObject {

    static let shared = AppIconCache()

    /// Bumps when any icon is newly cached. Observers (e.g. AppLauncherView)
    /// re-evaluate their body and call `icon(for:)` again to pick up the
    /// fresh bytes — do NOT bake this into a SwiftUI `.id(...)` modifier;
    /// that would force every visible cell to be discarded and rebuilt on
    /// every fetch tick rather than letting bodies update in place.
    @Published var version: Int = 0

    private let cacheDir: URL
    private let session: URLSession
    private let stalenessInterval: TimeInterval = 12 * 60 * 60
    private var refreshTask: Task<Void, Never>?
    /// In-memory NSImage cache so icon(for:) doesn't hit disk on every render.
    private var memCache: [String: NSImage] = [:]
    /// Bundle IDs for which iTunes returned no results — skip on future fetches.
    private var notFoundIDs: Set<String> = []

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = base.appendingPathComponent("com.adhir.appletv-remote/icons", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Return the icon for a bundle ID.
    /// Bundled icons (in Resources/AppIcons/) take precedence over the network cache.
    /// Results are kept in a memory cache so SwiftUI render passes don't hit disk.
    func icon(for bundleID: String) -> NSImage? {
        if let cached = memCache[bundleID] { return cached }
        // 1. Check app bundle first — authoritative, survives cache clears.
        if let url = bundleResourceURL(forResource: bundleID, withExtension: "png", subdirectory: "AppIcons"),
           let img = NSImage(contentsOf: url) {
            memCache[bundleID] = img
            return img
        }
        // 2. Fall back to network-fetched cache.
        let cached = cacheDir.appendingPathComponent("\(bundleID).png")
        guard FileManager.default.fileExists(atPath: cached.path),
              let img = NSImage(contentsOf: cached) else { return nil }
        memCache[bundleID] = img
        return img
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

    private func isStale() -> Bool {
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
            // Skip icons that are bundled in the app — they never need network fetch.
            if bundleResourceURL(forResource: bundleID, withExtension: "png", subdirectory: "AppIcons") != nil { continue }
            // Skip IDs known to have no iTunes result this session.
            if notFoundIDs.contains(bundleID) { continue }
            let dest = cacheDir.appendingPathComponent("\(bundleID).png")
            // Skip if cached and fresh.
            if let mtime = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               Date().timeIntervalSince(mtime) < stalenessInterval {
                continue
            }
            do {
                try await fetchIcon(bundleID: bundleID, to: dest)
                await MainActor.run {
                    memCache.removeValue(forKey: bundleID)  // evict stale mem entry
                    version += 1
                }
                Log.app.report("AppIconCache: cached icon for \(bundleID)")
            } catch {
                if !Task.isCancelled {
                    Log.app.report("AppIconCache: failed to fetch icon for \(bundleID): \(error.localizedDescription)")
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func fetchIcon(bundleID: String, to dest: URL) async throws {
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
            // iTunes returned no results — record so we don't retry this session.
            await MainActor.run { notFoundIDs.insert(bundleID) }
            return
        }

        artworkURLString = artworkURLString.replacingOccurrences(of: "100x100bb", with: "200x200bb")
        guard let artworkURL = URL(string: artworkURLString) else { return }
        let (imageData, _) = try await session.data(from: artworkURL)
        guard let image = NSImage(data: imageData),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: dest)
    }
}

/// Returns a URL for a bundled resource, working under both SPM (Bundle.module)
/// and xcodebuild (Bundle.main).
private func bundleResourceURL(forResource name: String, withExtension ext: String, subdirectory: String) -> URL? {
    #if SWIFT_PACKAGE
    return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    #else
    return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    #endif
}
