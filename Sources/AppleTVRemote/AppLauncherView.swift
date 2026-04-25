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

    private let cellSize: CGFloat = 76   // icon 64 + padding 6×2
    private let spacing: CGFloat = 12

    private func columnCount(for width: CGFloat) -> Int {
        max(3, Int((width + spacing) / (cellSize + spacing)))
    }

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
                let core = filteredApps.filter { $0.id.hasPrefix("com.apple.") }
                let user = filteredApps.filter { !$0.id.hasPrefix("com.apple.") }
                let ordered = core + user
                GeometryReader { geo in
                    let cols = columnCount(for: geo.size.width - 24)  // 24 = horizontal padding
                    let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 12) {
                                if !core.isEmpty {
                                    appGrid(apps: core, offset: 0, columns: columns)
                                }
                                if !core.isEmpty && !user.isEmpty {
                                    Divider().opacity(0.4).padding(.horizontal, 24)
                                }
                                if !user.isEmpty {
                                    appGrid(apps: user, offset: core.count, columns: columns)
                                }
                            }
                            .animation(.easeInOut(duration: 0.25), value: cols)
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
                            handleKey(keyCode, apps: ordered, cols: cols)
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func appGrid(apps: [(id: String, name: String)], offset: Int,
                         columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                let idx = offset + i
                AppCell(app: app, iconCache: iconCache, isFocused: idx == focusedIndex) {
                    guard !PopoverActivationGuard.shared.isActivationClick else { return }
                    connection.launchApp(bundleID: app.id)
                    withAnimation(.easeInOut(duration: 0.18)) { showAppLauncher = false }
                }
                .id(idx)
                .onTapGesture { focusedIndex = idx }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
    }

    // Key codes: left=123 right=124 down=125 up=126 return=36 r=15
    private func handleKey(_ keyCode: UInt16, apps: [(id: String, name: String)], cols: Int) {
        if keyCode == 15 {
            withAnimation(.easeInOut(duration: 0.18)) { showAppLauncher = false }
            return
        }
        let count = apps.count
        guard count > 0 else { return }
        switch keyCode {
        case 123: focusedIndex = max(0, focusedIndex - 1)
        case 124: focusedIndex = min(count - 1, focusedIndex + 1)
        case 126:
            let next = focusedIndex - cols
            if next >= 0 { focusedIndex = next }
        case 125:
            let next = focusedIndex + cols
            if next < count { focusedIndex = next }
        case 36:
            guard focusedIndex < apps.count else { return }
            connection.launchApp(bundleID: apps[focusedIndex].id)
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
                    // 'r' exits launcher unless a text field has focus
                    if code == 15 {
                        let inField = (event.window?.firstResponder as? NSText) != nil
                        if !inField {
                            DispatchQueue.main.async { self?.onKey?(code) }
                            return nil
                        }
                        return event
                    }
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
