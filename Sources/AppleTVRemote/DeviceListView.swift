import SwiftUI
import AppleTVProtocol
import AppKit

// MARK: - Delayed tooltip helper

private struct DelayedTooltip: NSViewRepresentable {
    let text: String
    let delay: TimeInterval

    func makeNSView(context: Context) -> TooltipView {
        TooltipView(text: text, delay: delay)
    }

    func updateNSView(_ nsView: TooltipView, context: Context) {
        nsView.tooltipText = text
        nsView.delay = delay
    }

    final class TooltipView: NSView {
        var tooltipText: String
        var delay: TimeInterval
        private var timer: Timer?
        private var trackingArea: NSTrackingArea?
        private weak var tooltipPanel: NSPanel?

        init(text: String, delay: TimeInterval) {
            self.tooltipText = text
            self.delay = delay
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { false }

        override func keyDown(with event: NSEvent) {
            nextResponder?.keyDown(with: event)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let ta = trackingArea { removeTrackingArea(ta) }
            let ta = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(ta)
            trackingArea = ta
        }

        override func mouseEntered(with event: NSEvent) {
            timer?.invalidate()
            let capturedEvent = event
            timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.showPanel(near: capturedEvent)
            }
        }

        override func mouseExited(with event: NSEvent) {
            timer?.invalidate()
            timer = nil
            hidePanel()
        }

        private func showPanel(near event: NSEvent) {
            hidePanel()

            let label = NSTextField(labelWithString: tooltipText)
            label.font = NSFont.preferredFont(forTextStyle: .subheadline)
            label.textColor = .white
            label.sizeToFit()

            let padding: CGFloat = 5
            let contentSize = CGSize(
                width: label.frame.width + padding * 2,
                height: label.frame.height + padding * 2
            )

            let mouseScreen = NSEvent.mouseLocation
            let origin = CGPoint(x: mouseScreen.x + 12, y: mouseScreen.y - contentSize.height - 4)

            let panel = NSPanel(
                contentRect: CGRect(origin: origin, size: contentSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .popUpMenu
            panel.hasShadow = true
            panel.ignoresMouseEvents = true

            let container = NSView(frame: CGRect(origin: .zero, size: contentSize))
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 0.95).cgColor
            container.layer?.cornerRadius = 5
            container.layer?.masksToBounds = true

            label.frame = CGRect(x: padding, y: padding, width: label.frame.width, height: label.frame.height)
            container.addSubview(label)

            panel.contentView = container
            panel.orderFront(nil)
            tooltipPanel = panel
        }

        private func hidePanel() {
            tooltipPanel?.orderOut(nil)
            tooltipPanel = nil
        }
    }
}

// MARK: - Auto-connect store

final class AutoConnectStore: ObservableObject {
    private let key = "com.adhir.appletv-remote.autoConnectDeviceIDs"

    @Published private(set) var deviceIDs: Set<String>

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "com.adhir.appletv-remote.autoConnectDeviceIDs") ?? []
        deviceIDs = Set(saved)
    }

    func isEnabled(_ id: String) -> Bool { deviceIDs.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        if on { deviceIDs.insert(id) } else { deviceIDs.remove(id) }
        UserDefaults.standard.set(Array(deviceIDs), forKey: key)
    }
}

// MARK: - Device list

struct DeviceListView: View {
    @EnvironmentObject private var discovery: DeviceDiscovery
    @EnvironmentObject private var autoConnect: AutoConnectStore
    @Binding var selectedDevice: AppleTVDevice?
    @AppStorage("com.adhir.appletv-remote.hideWindowAtStartup") private var hideWindowAtStartup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if discovery.devices.isEmpty {
                emptyState
            } else {
                List(discovery.devices, selection: $selectedDevice) { device in
                    DeviceRow(
                        device: device,
                        autoConnect: Binding(
                            get: { autoConnect.isEnabled(device.id) },
                            set: { autoConnect.setEnabled(device.id, $0) }
                        )
                    )
                    .tag(device)
                }
                .listStyle(.sidebar)
            }

            Divider()

            HStack {
                Text("Hide window at startup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $hideWindowAtStartup)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.7)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var header: some View {
        HStack {
            Text("Apple TVs")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if discovery.isSearching {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
            Button {
                discovery.stopDiscovery()
                discovery.startDiscovery()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Searching…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Make sure your Apple TV is on\nthe same Wi-Fi network.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct DeviceRow: View {
    let device: AppleTVDevice
    @Binding var autoConnect: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .overlay {
                        DelayedTooltip(text: device.name, delay: 0.2)
                    }
                if device.isPaired {
                    Text("Paired")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Auto-connect", isOn: $autoConnect)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.7)
                .help("Connect to this Apple TV at startup")
        }
        .padding(.vertical, 2)
    }
}
