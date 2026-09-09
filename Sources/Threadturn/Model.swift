import Foundation

enum Court: String, Codable { case ai, me, done }

struct Task: Codable, Identifiable {
    var id: String { key }
    var key: String            // "平台|标题"
    var platform: Platform
    var title: String
    var court: Court
    var at: Date               // 上次换边时间
    var wakeAt: Date?          // 稍后：到这个时间前藏起来
    var seen: Bool = false     // 轮到我 之后你有没有看过
    var sideRunning: Bool?     // Claude 侧栏上一次的运行状态
    var replySig: String?      // 上次看到的回复签名
    var sidePreview: String?   // Grok 侧栏上次的预览
    var flips: Int = 0
    var hidden: Bool = false   // 「忽略」：留着记录但不显示，来新回复再冒出来
    var obsSig: String?        // 上一轮读到的签名（用来判断回复是否已经稳定）
    var lastNotified: Date?    // 上次提醒时间（限频）

    init(key: String, platform: Platform, title: String, court: Court, at: Date, wakeAt: Date?) {
        self.key = key; self.platform = platform; self.title = title; self.court = court; self.at = at; self.wakeAt = wakeAt
    }
    /// 旧版本文件缺新字段时用默认值，绝不整文件作废
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        platform = try c.decode(Platform.self, forKey: .platform)
        title = try c.decode(String.self, forKey: .title)
        court = try c.decode(Court.self, forKey: .court)
        at = try c.decode(Date.self, forKey: .at)
        wakeAt = try c.decodeIfPresent(Date.self, forKey: .wakeAt)
        seen = try c.decodeIfPresent(Bool.self, forKey: .seen) ?? false
        sideRunning = try c.decodeIfPresent(Bool.self, forKey: .sideRunning)
        replySig = try c.decodeIfPresent(String.self, forKey: .replySig)
        sidePreview = try c.decodeIfPresent(String.self, forKey: .sidePreview)
        flips = try c.decodeIfPresent(Int.self, forKey: .flips) ?? 0
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        obsSig = try c.decodeIfPresent(String.self, forKey: .obsSig)
        lastNotified = try c.decodeIfPresent(Date.self, forKey: .lastNotified)
    }

    var bucket: Bucket {
        switch court {
        case .done: return .done
        case .ai: return .ai
        case .me: if let w = wakeAt, w > Date() { return .later }; return .me
        }
    }
}

enum Bucket: String, CaseIterable, Identifiable {
    case me, ai, later, done
    var id: String { rawValue }
    var label: String {
        switch self {
        case .me: return "轮到我"
        case .ai: return "等 AI"
        case .later: return "稍后"
        case .done: return "已完成"
        }
    }
}

struct Event {
    var platform: Platform
    var title: String
    var body: String
}

final class Store: ObservableObject {
    @Published private(set) var tasks: [String: Task] = [:]
    @Published var paused = false
    @Published var lastPoll: Date?
    @Published var permissionOK = true
    @Published var appsSeen: [Platform: Bool] = [:]

    private let url: URL
    private(set) var loadFailed = false

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Threadturn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("state.json")
        // 从旧名字迁移
        let old = dir.deletingLastPathComponent().appendingPathComponent("Rally/state.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: url)
        }
        if let d = try? Data(contentsOf: url) {
            if let t = try? JSONDecoder().decode([Task].self, from: d) {
                tasks = Dictionary(t.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            } else {
                // 解析失败：把坏文件留下来，不覆盖
                let broken = dir.appendingPathComponent("state.broken-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: broken)
                loadFailed = true
            }
        }
    }

    func save() {
        let arr = Array(tasks.values)
        guard let d = try? JSONEncoder().encode(arr) else { return }
        let bak = url.deletingLastPathComponent().appendingPathComponent("state.bak.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: url, to: bak)
        }
        try? d.write(to: url, options: .atomic)
    }

    func list(_ b: Bucket) -> [Task] {
        let l = tasks.values.filter { $0.bucket == b && !$0.hidden }
        switch b {
        case .me: return l.sorted { $0.at < $1.at }
        case .ai: return l.sorted { $0.at < $1.at }
        case .later: return l.sorted { ($0.wakeAt ?? .distantPast) < ($1.wakeAt ?? .distantPast) }
        case .done: return Array(l.sorted { $0.at > $1.at }.prefix(8))
        }
    }
    func count(_ b: Bucket) -> Int { tasks.values.filter { $0.bucket == b && !$0.hidden }.count }

    // MARK: 手动操作
    func done(_ key: String) { mutate(key) { $0.court = .done; $0.at = Date(); $0.wakeAt = nil } }
    func snooze(_ key: String, minutes: Int) { mutate(key) { $0.wakeAt = Date().addingTimeInterval(Double(minutes) * 60) } }
    func now(_ key: String) { mutate(key) { $0.wakeAt = nil } }
    func restore(_ key: String) { mutate(key) { $0.court = .me; $0.at = Date(); $0.wakeAt = nil; $0.seen = false; $0.hidden = false } }
    func remove(_ key: String) { mutate(key) { $0.court = .done; $0.at = Date(); $0.wakeAt = nil; $0.hidden = true } }
    private func mutate(_ key: String, _ f: (inout Task) -> Void) {
        guard var t = tasks[key] else { return }
        f(&t); tasks[key] = t; save()
    }

    // MARK: 自动判定
    /// 把一轮读取结果并进状态，返回需要通知的事件。
    func apply(_ snaps: [AppSnapshot], frontmostApp: String?) -> [Event] {
        var events: [Event] = []
        let now = Date()
        for s in snaps {
            appsSeen[s.platform] = s.running
            guard s.running else { continue }

            // 1. 前台会话
            if let f = s.front, let title = f.title, !title.isEmpty {
                let key = "\(s.platform.rawValue)|\(title)"
                var t = tasks[key]
                switch f.observed {
                case .waiting:
                    if t == nil {
                        t = Task(key: key, platform: s.platform, title: title, court: .ai, at: now, wakeAt: nil)
                    } else if t!.court != .ai {
                        t!.court = .ai; t!.at = now; t!.wakeAt = nil; t!.seen = false; t!.flips += 1
                    }
                    t!.replySig = nil
                case .replied:
                    if var x = t {
                        let sig = f.sig
                        // 回复还在一个字一个字往外冒时签名每轮都变；连续两轮不变才算回完
                        let stable = (x.obsSig == sig)
                        x.obsSig = sig
                        let viewing = (frontmostApp == s.platform.appName)   // 你正在这条对话里
                        if stable {
                            switch x.court {
                            case .ai:
                                x.court = .me; x.at = now; x.wakeAt = nil; x.seen = viewing; x.flips += 1; x.hidden = false
                                if !viewing { events.append(Event(platform: s.platform, title: title, body: "回了，轮到你。")) }
                            case .done:
                                // 已完成之后又来了新回复：自动放回
                                if let old = x.replySig, old != sig {
                                    x.court = .me; x.at = now; x.wakeAt = nil; x.seen = viewing; x.flips += 1; x.hidden = false
                                    if !viewing { events.append(Event(platform: s.platform, title: title, body: "又回了一条，放回「轮到我」。")) }
                                }
                            case .me:
                                if let old = x.replySig, old != sig, f.messages > (Int(old.split(separator: "|").first ?? "0") ?? 0) {
                                    x.at = now; x.seen = viewing; x.wakeAt = nil
                                    if !viewing { events.append(Event(platform: s.platform, title: title, body: "又回了一条。")) }
                                }
                            }
                            x.replySig = sig
                        }
                        if viewing, x.court == .me { x.seen = true }
                        t = x
                    }
                    // 第一次见就已经是 AI 回过的历史会话：不记，免得把老会话全翻出来
                case .unknown: break
                }
                if let x = t { tasks[key] = x }
            }

            // 2. Claude 侧栏：后台会话 Running → Idle
            for c in s.side where c.running != nil {
                let key = "\(s.platform.rawValue)|\(c.title)"
                let running = c.running!
                if var t = tasks[key] {
                    if running, t.court != .ai {
                        t.court = .ai; t.at = now; t.wakeAt = nil; t.seen = false; t.flips += 1
                    } else if !running, t.sideRunning == true, t.court == .ai {
                        // 前台那条由前台逻辑负责；这里只管不在前台的
                        if s.front?.title != c.title {
                            t.court = .me; t.at = now; t.wakeAt = nil; t.seen = false; t.flips += 1; t.hidden = false
                            events.append(Event(platform: s.platform, title: c.title, body: "后台跑完了，轮到你。"))
                        }
                    }
                    t.sideRunning = running
                    tasks[key] = t
                } else if running {
                    var t = Task(key: key, platform: s.platform, title: c.title, court: .ai, at: now, wakeAt: nil)
                    t.sideRunning = true
                    tasks[key] = t
                }
            }

            // 3. Grok「X 已回复」+ 侧栏预览变化
            let noticed = Set(s.repliedNotices.filter { !$0.isEmpty })
            for c in s.side where c.preview != nil {
                let key = "\(s.platform.rawValue)|\(c.title)"
                let preview = c.preview!
                let hasNotice = noticed.contains(c.title)
                let viewing = (frontmostApp == s.platform.appName && s.front?.title == c.title)
                if var t = tasks[key] {
                    let changed = (t.sidePreview != nil && t.sidePreview != preview)
                    if hasNotice && t.court == .ai {
                        t.court = .me; t.at = now; t.wakeAt = nil; t.seen = viewing; t.flips += 1; t.hidden = false
                        if !viewing { events.append(Event(platform: s.platform, title: c.title, body: "回了，轮到你。")) }
                    } else if hasNotice && changed && t.court == .done {
                        t.court = .me; t.at = now; t.wakeAt = nil; t.seen = viewing; t.flips += 1; t.hidden = false
                        if !viewing { events.append(Event(platform: s.platform, title: c.title, body: "又回了一条，放回「轮到我」。")) }
                    } else if hasNotice && changed && t.court == .me {
                        t.at = now; t.seen = false
                    }
                    if hasNotice || t.sidePreview == nil { t.sidePreview = preview }
                    tasks[key] = t
                } else if hasNotice {
                    var t = Task(key: key, platform: s.platform, title: c.title, court: .me, at: now, wakeAt: nil)
                    t.sidePreview = preview; t.seen = viewing
                    tasks[key] = t
                    if !viewing { events.append(Event(platform: s.platform, title: c.title, body: "回了，轮到你。")) }
                }
            }
        }
        // 4. 清理：完成超过 7 天的
        for (k, t) in tasks where t.court == .done && now.timeIntervalSince(t.at) > (t.hidden ? 60 : 7) * 86400 { tasks[k] = nil }
        lastPoll = now
        save()
        // 同一条同一轮只通知一次；同一条 10 分钟内不重复提醒
        var seenKeys = Set<String>()
        var out: [Event] = []
        for e in events {
            let k = "\(e.platform.rawValue)|\(e.title)"
            guard seenKeys.insert(k).inserted else { continue }
            if let t = tasks[k], let ln = t.lastNotified, now.timeIntervalSince(ln) < 600 { continue }
            tasks[k]?.lastNotified = now
            out.append(e)
        }
        if !out.isEmpty { save() }
        return out
    }
}

func ago(_ d: Date) -> String {
    let m = Int(Date().timeIntervalSince(d) / 60)
    if m < 1 { return "刚刚" }
    if m < 60 { return "\(m) 分钟" }
    let h = m / 60
    if h < 24 { return "\(h) 小时" }
    return "\(h / 24) 天"
}
