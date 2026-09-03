import AppKit
import FlareBarCore
import Observation
import ServiceManagement
import UserNotifications

enum Connection: Equatable {
    case loading
    case ready
    case noToken
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    var snapshot: UsageSnapshot?
    var connection: Connection = .loading
    var isRefreshing = false
    var tokenDraft = ""
    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var failCount = 0
    @ObservationIgnored private var lastMenuOpen = Date.distantPast
    @ObservationIgnored private var notified: Set<String> = []

    init() {
        notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        if let data = UserDefaults.standard.data(forKey: "snapshot"),
           let snap = try? JSONDecoder().decode(UsageSnapshot.self, from: data) {
            snapshot = snap
        }
    }

    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func markMenuOpened() { lastMenuOpen = .now }

    func start() {
        refresh()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.refreshInterval() ?? 120
                try? await Task.sleep(for: .seconds(interval))
                self?.refresh()
            }
        }
    }

    func refreshInterval() -> TimeInterval {
        let idle = Date.now.timeIntervalSince(lastMenuOpen)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 1800 }
        if idle < 300 { return 120 }
        if idle < 900 { return 300 }
        if idle < 3600 { return 900 }
        return 1800
    }

    func refresh() {
        guard !isRefreshing else { return }
        refreshTask = Task { [weak self] in await self?.performRefresh() }
    }

    func saveToken() {
        let t = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try? TokenStore.save(t)
        tokenDraft = ""
        refresh()
    }

    func toggleLogin() {
        try? (loginEnabled ? SMAppService.mainApp.unregister() : SMAppService.mainApp.register())
    }

    func quit() { NSApp.terminate(nil) }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        guard let token = TokenStore.load() else {
            connection = .noToken
            return
        }
        do {
            let snap = try await CloudflareClient(token: token).snapshot()
            snapshot = snap
            connection = .ready
            failCount = 0
            if let data = try? JSONEncoder().encode(snap) {
                UserDefaults.standard.set(data, forKey: "snapshot")
            }
            notifyThresholds(snap)
        } catch {
            failCount += 1
            if snapshot == nil || failCount >= 2 {
                if case .http(401, _) = error as? CloudflareError {
                    connection = .noToken
                } else {
                    connection = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func notifyThresholds(_ snap: UsageSnapshot) {
        guard notificationsEnabled else { return }
        for bar in snap.bars {
            let day = CloudflareClient.utcDate()
            if bar.percent >= 95 {
                ping(id: "\(bar.id)-95-\(day)", title: "\(bar.title) 95%", body: String(format: "%.0f%% of %@", bar.percent, bar.unit))
            } else if bar.percent >= 80 {
                ping(id: "\(bar.id)-80-\(day)", title: "\(bar.title) 80%", body: String(format: "%.0f%% of %@", bar.percent, bar.unit))
            }
        }
    }

    private func ping(id: String, title: String, body: String) {
        guard !notified.contains(id) else { return }
        notified.insert(id)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            let r = UNNotificationRequest(identifier: id, content: c, trigger: nil)
            UNUserNotificationCenter.current().add(r)
        }
    }
}
