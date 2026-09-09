import AppKit
import ApplicationServices

/// 一个辅助功能树节点的轻量快照。
final class Node {
    let el: AXUIElement
    let role: String
    let desc: String
    let value: String
    let classes: Set<String>
    var kids: [Node] = []

    init(_ el: AXUIElement, depth: Int) {
        self.el = el
        role = AX.str(el, "AXRole")
        desc = AX.str(el, "AXDescription")
        value = AX.str(el, "AXValue")
        if let arr = AX.raw(el, "AXDOMClassList") as? [Any] {
            classes = Set(arr.compactMap { $0 as? String })
        } else {
            classes = []
        }
        if depth < 70, let children = AX.raw(el, "AXChildren") as? [AXUIElement] {
            kids = children.map { Node($0, depth: depth + 1) }
        }
    }

    var text: String { value.isEmpty ? desc : value }

    func walk(_ f: (Node) -> Void) {
        f(self)
        for k in kids { k.walk(f) }
    }
    func find(_ pred: (Node) -> Bool) -> [Node] {
        var out: [Node] = []
        walk { if pred($0) { out.append($0) } }
        return out
    }
    func first(_ pred: (Node) -> Bool) -> Node? {
        var hit: Node?
        var done = false
        func rec(_ n: Node) {
            if done { return }
            if pred(n) { hit = n; done = true; return }
            for k in n.kids { rec(k); if done { return } }
        }
        rec(self)
        return hit
    }
    func staticTexts() -> [String] {
        find { $0.role == "AXStaticText" && !$0.value.isEmpty }.map { $0.value }
    }
}

enum AX {
    static func raw(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &v)
        return err == .success ? v : nil
    }
    static func str(_ el: AXUIElement, _ attr: String) -> String {
        (raw(el, attr) as? String) ?? ""
    }
    static func trusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
    static func appElement(_ name: String) -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return el
    }
    static func windowTree(_ name: String) -> Node? {
        guard let app = appElement(name), let wins = raw(app, "AXWindows") as? [AXUIElement], let w = wins.first else { return nil }
        return Node(w, depth: 0)
    }
    static func press(_ n: Node) {
        AXUIElementPerformAction(n.el, kAXPressAction as CFString)
    }
}

// MARK: - 三个客户端的解析

enum Platform: String, Codable, CaseIterable {
    case chatgpt = "ChatGPT", claude = "Claude", grok = "Grok Bot"
    var appName: String { rawValue }
    var short: String { self == .grok ? "Grok" : rawValue }
}

enum Observed { case waiting, replied, unknown }

struct FrontConversation {
    var title: String?
    var observed: Observed
    var generating: Bool
    var messages: Int
    var lastText: String = ""
    /// 回复签名：变了就说明又有新消息
    var sig: String { "\(messages)|\(lastText.prefix(40))" }
}

struct SideConversation {
    var title: String
    var running: Bool?      // Claude 才有
    var preview: String?    // Grok 才有：时间 + 最后一句
}

struct AppSnapshot {
    var platform: Platform
    var running: Bool
    var front: FrontConversation?
    var side: [SideConversation]
    var repliedNotices: [String]   // Grok「X 已回复」
}

enum Parsers {
    static func snapshot(_ p: Platform) -> AppSnapshot {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == p.appName }) else {
            return AppSnapshot(platform: p, running: false, front: nil, side: [], repliedNotices: [])
        }
        guard let root = AX.windowTree(p.appName) else {
            return AppSnapshot(platform: p, running: true, front: nil, side: [], repliedNotices: [])
        }
        switch p {
        case .chatgpt: return chatgpt(root)
        case .claude: return claude(root)
        case .grok: return grok(root)
        }
    }

    private static func observed(last: String?, generating: Bool) -> Observed {
        if generating { return .waiting }
        if last == "user" { return .waiting }
        if last == "assistant" { return .replied }
        return .unknown
    }

    static func chatgptChatButtons(_ root: Node) -> [Node] {
        root.find { n in
            n.role == "AXButton" && n.first { k in k !== n && k.role == "AXButton" && (k.desc == "Pin chat" || k.desc == "Unpin chat") } != nil
        }
    }

    static func chatgpt(_ root: Node) -> AppSnapshot {
        var side: [SideConversation] = []
        var title: String?
        for b in chatgptChatButtons(root) {
            let t = b.desc.isEmpty ? (b.staticTexts().first ?? "") : b.desc
            side.append(SideConversation(title: t, running: nil))
            if b.classes.contains("bg-primary-ghost-hover") { title = t }
        }
        let heads = root.find { $0.role == "AXHeading" && ($0.kids.first?.value == "You said:" || $0.kids.first?.value == "ChatGPT said:") }
        var last: String?
        if let h = heads.last { last = h.kids.first!.value.hasPrefix("You") ? "user" : "assistant" }
        let generating = root.first { $0.role == "AXButton" && $0.desc.lowercased().contains("stop") } != nil
        if title == nil, !heads.isEmpty { title = "（未命名会话）" }
        let front = FrontConversation(title: title, observed: observed(last: last, generating: generating), generating: generating, messages: heads.count)
        return AppSnapshot(platform: .chatgpt, running: true, front: heads.isEmpty ? nil : front, side: side, repliedNotices: [])
    }

    static func claude(_ root: Node) -> AppSnapshot {
        var side: [SideConversation] = []
        for b in root.find({ n in n.role == "AXButton" && n.first { ($0.role == "AXImage" || $0.role == "AXGroup") && ($0.desc == "Idle" || $0.desc == "Running") } != nil }) {
            let st = b.first { ($0.role == "AXImage" || $0.role == "AXGroup") && ($0.desc == "Idle" || $0.desc == "Running") }!
            let name = b.staticTexts().first ?? ""
            if !name.isEmpty { side.append(SideConversation(title: name, running: st.desc == "Running")) }
        }
        var title: String?
        if let tb = root.first({ $0.role == "AXButton" && $0.desc.hasSuffix(", rename session") }) {
            title = String(tb.desc.dropLast(", rename session".count))
        }
        let heads = root.find { n in
            guard n.role == "AXHeading", let v = n.kids.first?.value else { return false }
            return v.hasPrefix("You said:") || v.hasPrefix("Claude responded:")
        }
        var last: String?
        if let h = heads.last { last = h.kids.first!.value.hasPrefix("You") ? "user" : "assistant" }
        let generating = root.first { $0.desc == "Currently streaming message" || $0.value == "Claude is responding" } != nil
        let front = FrontConversation(title: title, observed: observed(last: last, generating: generating), generating: generating, messages: heads.count)
        return AppSnapshot(platform: .claude, running: true, front: (title == nil && heads.isEmpty) ? nil : front, side: side, repliedNotices: [])
    }

    static func grok(_ root: Node) -> AppSnapshot {
        var side: [SideConversation] = []
        if let list = root.first({ $0.role == "AXGroup" && $0.desc == "Bot 列表" }) {
            for b in list.find({ $0.role == "AXButton" }) where !b.desc.isEmpty {
                let texts = b.staticTexts()
                side.append(SideConversation(title: b.desc, running: nil, preview: texts.dropFirst().joined(separator: "|")))
            }
        }
        var title: String?
        if let h = root.first({ $0.role == "AXHeading" }) {
            title = h.desc.isEmpty ? h.staticTexts().first : h.desc
        }
        var last: String?
        var count = 0
        var lastText = ""
        if let log = root.first({ $0.role == "AXGroup" && $0.desc == "对话记录" }) {
            let msgs = log.find { $0.role == "AXGroup" && ($0.desc.hasSuffix(" 的消息") || $0.desc == "你的回答") }
            count = msgs.count
            if let m = msgs.last { last = m.desc == "你的回答" ? "user" : "assistant"; lastText = m.staticTexts().joined(separator: " ") }
        }
        let notices = root.find { $0.role == "AXStaticText" && $0.value.hasSuffix("已回复") }
            .map { String($0.value.dropLast("已回复".count)).trimmingCharacters(in: .whitespaces) }
        let generating = root.first { $0.role == "AXButton" && ($0.desc == "停止" || $0.desc == "停止生成") } != nil
        let front = FrontConversation(title: title, observed: observed(last: last, generating: generating), generating: generating, messages: count, lastText: lastText)
        return AppSnapshot(platform: .grok, running: true, front: title == nil ? nil : front, side: side, repliedNotices: notices)
    }

    /// 激活应用并尝试点到那条会话。
    static func open(_ p: Platform, title: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == p.appName }) {
            app.activate(options: [.activateIgnoringOtherApps])
        } else {
            NSWorkspace.shared.launchApplication(p.appName)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            guard let root = AX.windowTree(p.appName) else { return }
            let target: Node?
            switch p {
            case .chatgpt: target = chatgptChatButtons(root).first { $0.desc == title }
            case .claude: target = root.first { n in n.role == "AXButton" && n.staticTexts().first == title && n.first { ($0.role == "AXImage" || $0.role == "AXGroup") && ($0.desc == "Idle" || $0.desc == "Running") } != nil }
            case .grok:
                let list = root.first { $0.role == "AXGroup" && $0.desc == "Bot 列表" }
                target = list?.first { $0.role == "AXButton" && $0.desc == title }
            }
            if let t = target { AX.press(t) }
        }
    }
}
