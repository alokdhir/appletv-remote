import SwiftUI
import AppKit

/// Grid of launchable apps fetched from the ATV.
/// Shown in place of the remote layout when the user taps the app-grid button.
struct AppLauncherView: View {
    @ObservedObject var connection: CompanionConnection
    @ObservedObject var iconCache: AppIconCache
    @Binding var showAppLauncher: Bool

    @State private var searchText = ""
    @State private var focusedIndex: Int = 0

    private let columnCount = 3
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    private var filteredApps: [(id: String, name: String)] {
        guard !searchText.isEmpty else { return connection.appList }
        return connection.appList.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onChange(of: searchText) { _ in focusedIndex = 0 }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
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
                    ProgressView().scaleEffect(0.7)
                    Text("Loading apps…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            } else if filteredApps.isEmpty {
                Spacer()
                Text("No apps match \"\(searchText)\"").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(Array(filteredApps.enumerated()), id: \.element.id) { idx, app in
                                AppCell(app: app, iconCache: iconCache, isFocused: idx == focusedIndex) {
                                    connection.launchApp(bundleID: app.id)
                                    withAnimation(.easeInOut(duration: 0.18)) { showAppLauncher = false }
                                }
                                .id(idx)
                                .onTapGesture { focusedIndex = idx }
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: filteredApps.map(\.id))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: focusedIndex) { idx in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
                .background(
                    KeyMonitor { [self] keyCode in
                        handleKey(keyCode, count: filteredApps.count)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Arrow key codes: left=123 right=124 down=125 up=126 return=36
    private func handleKey(_ keyCode: UInt16, count: Int) {
        guard count > 0 else { return }
        switch keyCode {
        case 123: focusedIndex = max(0, focusedIndex - 1)
        case 124: focusedIndex = min(count - 1, focusedIndex + 1)
        case 126:
            let next = focusedIndex - columnCount
            if next >= 0 { focusedIndex = next }
        case 125:
            let next = focusedIndex + columnCount
            if next < count { focusedIndex = next }
        case 36:
            let app = filteredApps[focusedIndex]
            connection.launchApp(bundleID: app.id)
            withAnimation(.easeInOut(duration: 0.18)) { showAppLauncher = false }
        default: break
        }
    }
}

/// Invisible NSView that installs a local key-down monitor while it's in the window.
private struct KeyMonitor: NSViewRepresentable {
    let onKey: (UInt16) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onKey = onKey
    }

    private class MonitorView: NSView {
        var onKey: ((UInt16) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let code = event.keyCode
                    if [36, 123, 124, 125, 126].contains(code) {
                        DispatchQueue.main.async { self?.onKey?(code) }
                        return nil
                    }
                    return event
                }
            } else {
                if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            }
        }
    }
}

private struct AppCell: View {
    let app: (id: String, name: String)
    @ObservedObject var iconCache: AppIconCache
    var isFocused: Bool = false
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
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Text(app.name)
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(
                isFocused ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .id("\(app.id)-\(iconCache.version)")
    }
}
