import AppKit
import FlareBarCore
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: NSPanel
    private var eventMonitor: Any?

    init(model: AppModel) {
        self.model = model
        let hosting = NSHostingView(rootView: MenuBarView().environment(model))
        hosting.frame = NSRect(origin: .zero, size: MenuBarView.size)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: MenuBarView.size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        super.init()
        statusItem.autosaveName = "FlareBarStatusItem"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        updateIcon()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    @objc private func toggle() {
        panel.isVisible ? close() : open()
    }

    private func open() {
        model.markMenuOpened()
        model.refresh()
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? .zero
        let x = min(anchor.midX - MenuBarView.size.width / 2, visible.maxX - MenuBarView.size.width - 8)
        panel.setFrameTopLeftPoint(NSPoint(x: max(visible.minX + 8, x), y: anchor.minY - 4))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func close() {
        panel.orderOut(nil)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
    }

    private func updateIcon() {
        let bars = (model.snapshot?.bars ?? []).sorted { $0.percent > $1.percent }.prefix(model.iconBarCount).map(\.percent)
        let stale = model.connection != .ready && model.snapshot != nil
        statusItem.button?.image = IconRenderer.image(percents: Array(bars), count: model.iconBarCount, stale: stale || model.connection == .failed(""))
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = model.snapshot.map { snap in
            snap.bars.sorted { $0.percent > $1.percent }.prefix(model.iconBarCount)
                .map { String(format: "%@ %.0f%%", $0.title, $0.percent) }.joined(separator: "\n")
        } ?? "FlareBar"
    }
}

enum IconRenderer {
    static func image(percents: [Double], count: Int, stale: Bool) -> NSImage {
        let n = max(1, count)
        let w: CGFloat = 18, h: CGFloat = 18
        let gap: CGFloat = n > 3 ? 1 : 2
        let barH = min(4, (14 - gap * CGFloat(n - 1)) / CGFloat(n))
        let totalH = barH * CGFloat(n) + gap * CGFloat(n - 1)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let alpha: CGFloat = stale ? 0.4 : 1
            let x: CGFloat = 1, barW = rect.width - 2
            var y = rect.midY + totalH / 2 - barH
            for i in 0 ..< n {
                let track = NSRect(x: x, y: y, width: barW, height: barH)
                NSColor.labelColor.withAlphaComponent(0.25 * alpha).setFill()
                NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()
                let pct = i < percents.count ? min(100, max(0, percents[i])) : 0
                let fillW = max(barH, barW * CGFloat(pct / 100))
                NSColor.labelColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fillW, height: barH), xRadius: barH / 2, yRadius: barH / 2).fill()
                y -= barH + gap
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    static let size = NSSize(width: 280, height: 420)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch model.connection {
            case .noToken: tokenForm
            case .failed(let m): Text(m).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            case .loading: ProgressView().controlSize(.small)
            case .ready: EmptyView()
            }
            if let snap = model.snapshot {
                ForEach(snap.bars) { bar in
                    barRow(bar)
                }
                Text(snap.resetDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Text("Icon bars")
                Spacer()
                Picker("", selection: Bindable(model).iconBarCount) {
                    ForEach(1 ... 5, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }
            .font(.caption)
            .controlSize(.small)
            footer
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack {
            Text("FlareBar")
                .font(.headline)
            if let snap = model.snapshot {
                Text(snap.plan == .paid ? "Paid" : "Free")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Text(snap.accountName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.mini) }
            if let tag = model.snapshot?.accountTag {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://dash.cloudflare.com/\(tag)/workers-and-pages")!)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open dashboard")
            }
        }
    }

    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API token")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Paste token", text: Bindable(model).tokenDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            Button("Save") { model.saveToken() }
                .controlSize(.small)
            Text("Or wrangler login. Needs Analytics Read.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func barRow(_ bar: QuotaBar) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(bar.title)
                Spacer()
                Text(String(format: "%.0f%%", bar.percent))
                    .monospacedDigit()
                    .foregroundStyle(bar.percent >= 95 ? .red : bar.percent >= 80 ? .orange : .primary)
            }
            .font(.caption)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(bar.percent >= 95 ? Color.red : bar.percent >= 80 ? Color.orange : Color.primary.opacity(0.8))
                        .frame(width: max(4, g.size.width * CGFloat(min(100, bar.percent) / 100)))
                }
            }
            .frame(height: 6)
            Text("\(fmt(bar.used)) / \(fmt(bar.limit)) \(bar.unit)\(bar.sampled ? " · approx" : "")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh") { model.refresh() }
            Toggle("Alerts", isOn: Bindable(model).notificationsEnabled)
            Spacer()
            Button(model.loginEnabled ? "Login off" : "Login") { model.toggleLogin() }
            Button("Quit") { model.quit() }
        }
        .controlSize(.small)
        .font(.caption)
    }

    private func fmt(_ n: Double) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", n / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", n / 1_000) }
        return String(format: "%.0f", n)
    }
}
