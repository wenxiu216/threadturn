import AppKit
import SwiftUI
import UserNotifications
import os.log

let log = OSLog(subsystem: "com.threadturn.app", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = Store()
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    var timer: Timer?
    let queue = DispatchQueue(label: "poll", qos: .utility)
    var notificationsReady = false

    func applicationWillFinishLaunching(_ n: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.target = self
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store, onOpen: { [weak self] t in
            self?.popover.performClose(nil)
            Parsers.open(t.platform, title: t.title)
        }, onQuit: { NSApp.terminate(nil) }, onRequestPermission: { [weak self] in self?.requestPermission() }))
        // 系统辅助功能授权一变就立刻重查，不用等下一轮
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.poll() }
        }

        store.permissionOK = AX.trusted(prompt: true)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
                self.notificationsReady = ok
            }
        }
        // 调试：THREADTURN_TEST_NOTIFY=1 启动时，2 秒后对第一条「轮到我」发一条测试通知
        if ProcessInfo.processInfo.environment["THREADTURN_TEST_NOTIFY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let t = self.store.list(.me).first ?? self.store.list(.ai).first {
                    self.notify(Event(platform: t.platform, title: t.title, body: "测试通知，点我应该跳到这条对话。"))
                }
            }
        }
        refreshTitle()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let b = statusItem.button else { return }
        store.objectWillChange.send()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func requestPermission() {
        popover.performClose(nil)
        _ = AX.trusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func poll() {
        if store.paused { return }
        let trusted = AX.trusted(prompt: false)
        if !trusted { store.permissionOK = false; refreshTitle(); return }
        store.permissionOK = true
        let front = NSWorkspace.shared.frontmostApplication?.localizedName
        queue.async {
            let snaps = Platform.allCases.map { Parsers.snapshot($0) }
            DispatchQueue.main.async {
                let events = self.store.apply(snaps, frontmostApp: front)
                for e in events { self.notify(e) }
                self.refreshTitle()
            }
        }
    }

    func refreshTitle() {
        let me = store.count(.me)
        let ai = store.count(.ai)
        guard let b = statusItem.button else { return }
        let img = Bundle.main.image(forResource: "MenuBarIcon") ?? NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: "Threadturn")
        img?.isTemplate = true
        img?.size = NSSize(width: 18, height: 18)
        b.image = img
        b.imagePosition = .imageLeading
        b.title = !store.permissionOK ? " !" : (me > 0 ? " \(me)" : (ai > 0 ? " ·\(ai)" : ""))
        b.toolTip = "轮到我 \(me) · 等 AI \(ai)"
    }

    func notify(_ e: Event) {
        guard notificationsReady else { NSSound.beep(); return }
        let c = UNMutableNotificationContent()
        c.title = "\(e.platform.short) 回了"
        c.body = e.title
        c.sound = .default
        c.userInfo = ["platform": e.platform.rawValue, "title": e.title]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler h: @escaping () -> Void) {
        let u = r.notification.request.content.userInfo
        os_log("notification clicked: %{public}@", log: log, "\(u)")
        if let p = (u["platform"] as? String).flatMap(Platform.init(rawValue:)), let t = u["title"] as? String {
            Parsers.open(p, title: t)
        }
        h()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
