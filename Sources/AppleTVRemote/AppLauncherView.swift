import SwiftUI
import AppKit

/// Grid of launchable apps fetched from the ATV.
/// Shown in place of the remote layout when the user taps the app-grid button.
struct AppLauncherView: View {
    @ObservedObject var connection: CompanionConnection
    @ObservedObject var iconCache: AppIconCache
    @Binding var showAppLauncher: Bool

    @State private var searchText = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    private var filteredApps: [(id: String, name: String)] {
        guard !searchText.isEmpty else { return connection.appList }
        return connection.appList.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)

            if connection.appList.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading apps…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if filteredApps.isEmpty {
                Spacer()
                Text("No apps match \"\(searchText)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredApps, id: \.id) { app in
                            AppCell(app: app, iconCache: iconCache) {
                                connection.launchApp(bundleID: app.id)
                                showAppLauncher = false
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AppCell: View {
    let app: (id: String, name: String)
    @ObservedObject var iconCache: AppIconCache
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Group {
                    if let img = iconCache.icon(for: app.id) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Image(systemName: "app.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(app.name)
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(6)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        // Re-render when icon cache updates.
        .id("\(app.id)-\(iconCache.version)")
    }
}
