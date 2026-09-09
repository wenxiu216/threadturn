import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: Store
    var onOpen: (Task) -> Void
    var onQuit: () -> Void
    var onRequestPermission: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section(.me)
                    section(.ai)
                    if store.count(.later) > 0 { section(.later) }
                    if store.count(.done) > 0 { section(.done) }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 520)
    }

    var header: some View {
        HStack(spacing: 10) {
            Text("Threadturn").font(.system(size: 15, weight: .semibold))
            Spacer()
            if !store.permissionOK {
                Text("缺辅助功能权限").font(.system(size: 11)).foregroundColor(.red)
                Button("申请权限", action: onRequestPermission).font(.system(size: 11)).controlSize(.small)
            } else if store.paused {
                Text("已暂停").font(.system(size: 11)).foregroundColor(.secondary)
            } else if let p = store.lastPoll {
                Text("刚刚读过 · \(ago(p))前").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var footer: some View {
        HStack(spacing: 12) {
            ForEach(Platform.allCases, id: \.self) { p in
                HStack(spacing: 4) {
                    Circle().fill(color(p)).frame(width: 7, height: 7)
                    Text(p.short).font(.system(size: 11))
                        .foregroundColor(store.appsSeen[p] == true ? .primary : .secondary)
                }
            }
            Spacer()
            Toggle("监测", isOn: Binding(get: { !store.paused }, set: { store.paused = !$0 }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            Button("退出", action: onQuit).font(.system(size: 11)).buttonStyle(.plain).foregroundColor(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder
    func section(_ b: Bucket) -> some View {
        let items = store.list(b)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(b.label).font(.system(size: 11, weight: .semibold)).foregroundColor(bucketColor(b))
                Text("\(store.count(b))").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                Spacer()
            }
            if items.isEmpty {
                Text(b == .me ? "没有轮到你的事，安心做别的。" : "空").font(.system(size: 11)).foregroundColor(.secondary).padding(.vertical, 4)
            }
            ForEach(items) { t in row(t) }
        }
    }

    func row(_ t: Task) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(bucketColor(t.bucket)).frame(width: 3).padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(color(t.platform)).frame(width: 6, height: 6)
                    Text(t.platform.short).font(.system(size: 10)).foregroundColor(.secondary)
                    Text(stateText(t)).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    Spacer()
                }
                Text(t.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Button("打开 ↗") { onOpen(t) }.buttonStyle(.link).font(.system(size: 11))
                    Spacer()
                    actions(t)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    func actions(_ t: Task) -> some View {
        switch t.bucket {
        case .me:
            Menu("稍后") {
                Button("30 分钟") { store.snooze(t.key, minutes: 30) }
                Button("2 小时") { store.snooze(t.key, minutes: 120) }
                Button("明早 9 点") {
                    var c = Calendar.current.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(86400)); c.hour = 9
                    let d = Calendar.current.date(from: c)!
                    store.snooze(t.key, minutes: Int(d.timeIntervalSinceNow / 60))
                }
            }.menuStyle(.borderlessButton).font(.system(size: 11)).frame(width: 52)
            small("完成") { store.done(t.key) }
        case .ai:
            small("完成") { store.done(t.key) }
        case .later:
            small("现在") { store.now(t.key) }
            small("完成") { store.done(t.key) }
        case .done:
            small("放回") { store.restore(t.key) }
            small("忽略") { store.remove(t.key) }
        }
    }

    func small(_ label: String, _ f: @escaping () -> Void) -> some View {
        Button(label, action: f).font(.system(size: 11)).controlSize(.small)
    }

    func stateText(_ t: Task) -> String {
        switch t.bucket {
        case .me: return (t.seen ? "看了没回 · " : "回了 · ") + ago(t.at)
        case .ai: return "发出 " + ago(t.at)
        case .later: return "稍后 · " + (t.wakeAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "")
        case .done: return "已完成 · " + ago(t.at)
        }
    }

    func color(_ p: Platform) -> Color {
        switch p {
        case .chatgpt: return Color(red: 0.06, green: 0.64, blue: 0.5)
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .grok: return Color(red: 0.45, green: 0.5, blue: 0.62)
        }
    }
    func bucketColor(_ b: Bucket) -> Color {
        switch b {
        case .me: return Color(red: 0.75, green: 0.36, blue: 0.08)
        case .ai: return Color(red: 0.2, green: 0.5, blue: 0.54)
        case .later: return .secondary
        case .done: return Color(red: 0.32, green: 0.5, blue: 0.3)
        }
    }
}
