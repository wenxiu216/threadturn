#!/usr/bin/env python3
"""轮到谁 · 判定引擎
用 macOS 辅助功能读 ChatGPT / Claude / Grok Bot 客户端窗口，判断每个会话球在谁那。
不登录、不读账号、不发网络请求；只读你已经打开的窗口。
用法:  python3 engine.py            # 读一次，打印状态
       python3 engine.py --watch    # 每 4 秒读一次，打印变化
       python3 engine.py --json     # 读一次，输出 JSON
"""
import sys, time, json, re
from ApplicationServices import (AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
                                 AXUIElementSetAttributeValue, AXIsProcessTrusted)
from AppKit import NSWorkspace

APPS = ["ChatGPT", "Claude", "Grok Bot"]
MAX_DEPTH = 70

def ax(el, attr):
    try:
        err, val = AXUIElementCopyAttributeValue(el, attr, None)
        return val if err == 0 else None
    except Exception:
        return None

def s(v):
    return v if isinstance(v, str) else ""

class Node:
    __slots__ = ("role", "desc", "value", "title", "kids", "classes")
    def __init__(self, el, depth):
        self.role = s(ax(el, "AXRole"))
        self.desc = s(ax(el, "AXDescription"))
        self.value = s(ax(el, "AXValue"))
        self.title = s(ax(el, "AXTitle"))
        cl = ax(el, "AXDOMClassList")
        self.classes = set(str(c) for c in cl) if cl else set()
        self.kids = []
        if depth < MAX_DEPTH:
            for k in (ax(el, "AXChildren") or []):
                self.kids.append(Node(k, depth + 1))
    @property
    def text(self):
        return self.value or self.desc or self.title
    def walk(self):
        yield self
        for k in self.kids:
            yield from k.walk()
    def find(self, pred):
        return [n for n in self.walk() if pred(n)]
    def first(self, pred):
        for n in self.walk():
            if pred(n): return n
        return None
    def alltext(self, limit=80):
        out = []
        for n in self.walk():
            if n.role == "AXStaticText" and n.value:
                out.append(n.value)
        return " ".join(out)[:limit]

def read_app(name):
    apps = [a for a in NSWorkspace.sharedWorkspace().runningApplications() if a.localizedName() == name]
    if not apps:
        return None
    app = AXUIElementCreateApplication(apps[0].processIdentifier())
    AXUIElementSetAttributeValue(app, "AXManualAccessibility", True)
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface", True)
    wins = ax(app, "AXWindows") or []
    if not wins:
        return {"app": name, "running": True, "window": False}
    root = Node(wins[0], 0)
    return {"app": name, "running": True, "window": True, "tree": root}

# ---------- parsers ----------
def parse_chatgpt(root):
    convs = []
    title = None
    for b in root.find(lambda n: n.role == "AXButton" and any(k.role == "AXButton" and k.desc in ("Pin chat", "Unpin chat") for k in n.walk() if k is not n)):
        cur = "bg-primary-ghost-hover" in b.classes
        convs.append({"title": b.desc or b.alltext(60), "current": cur or None})
        if cur: title = b.desc
    heads = root.find(lambda n: n.role == "AXHeading" and any(k.value in ("You said:", "ChatGPT said:") for k in n.kids))
    last = None
    if heads:
        last = "user" if heads[-1].kids[0].value.startswith("You") else "assistant"
    generating = bool(root.first(lambda n: n.role == "AXButton" and re.search(r"stop", n.desc, re.I)))
    if title is None and heads:
        # 兜底：用第一条用户消息开头当标题
        first_user = next((h for h in heads if h.kids[0].value.startswith("You")), None)
        if first_user:
            title = "（无标题）"
    return {"conversations": convs, "front": {"title": title, "last": last, "messages": len(heads), "generating": generating}}

def parse_claude(root):
    convs = []
    for b in root.find(lambda n: n.role == "AXButton" and any(k.role in ("AXImage", "AXGroup") and k.desc in ("Idle", "Running") for k in n.walk())):
        st = b.first(lambda k: k.role in ("AXImage", "AXGroup") and k.desc in ("Idle", "Running"))
        name = b.first(lambda k: k.role == "AXStaticText" and k.value)
        convs.append({"title": name.value if name else "", "status": st.desc})
    for g in root.find(lambda n: n.role == "AXGroup" and n.desc == "Running"):
        pass
    title_btn = root.first(lambda n: n.role == "AXButton" and n.desc.endswith(", rename session"))
    title = title_btn.desc[:-len(", rename session")] if title_btn else None
    heads = root.find(lambda n: n.role == "AXHeading" and n.kids and (n.kids[0].value.startswith("You said:") or n.kids[0].value.startswith("Claude responded:")))
    last = None
    if heads:
        last = "user" if heads[-1].kids[0].value.startswith("You") else "assistant"
    generating = bool(root.first(lambda n: n.desc in ("Currently streaming message",) or n.value == "Claude is responding"))
    return {"conversations": convs, "front": {"title": title, "last": last, "messages": len(heads), "generating": generating}}

def parse_grok(root):
    convs = []
    lst = root.first(lambda n: n.role == "AXGroup" and n.desc == "Bot 列表")
    if lst:
        for b in lst.find(lambda n: n.role == "AXButton"):
            texts = [k.value for k in b.walk() if k.role == "AXStaticText" and k.value]
            convs.append({"title": b.desc, "time": texts[1] if len(texts) > 1 else "", "preview": texts[2][:40] if len(texts) > 2 else ""})
    h = root.first(lambda n: n.role == "AXHeading")
    title = h.desc or h.alltext(60) if h else None
    log = root.first(lambda n: n.role == "AXGroup" and n.desc == "对话记录")
    last, count = None, 0
    if log:
        msgs = log.find(lambda n: n.role == "AXGroup" and (n.desc.endswith(" 的消息") or n.desc == "你的回答"))
        count = len(msgs)
        if msgs:
            last = "user" if msgs[-1].desc == "你的回答" else "assistant"
    replied = [n.value for n in root.find(lambda n: n.role == "AXStaticText" and n.value.endswith("已回复"))]
    generating = bool(root.first(lambda n: n.role == "AXButton" and n.desc in ("停止", "停止生成")))
    return {"conversations": convs, "front": {"title": title, "last": last, "messages": count, "generating": generating}, "replied_notice": replied}

PARSERS = {"ChatGPT": parse_chatgpt, "Claude": parse_claude, "Grok Bot": parse_grok}

def court(front):
    if front["generating"]: return "AI 生成中"
    if front["last"] == "user": return "等 AI"
    if front["last"] == "assistant": return "轮到我"
    return "未知"

def snapshot():
    out = {}
    for name in APPS:
        t0 = time.time()
        r = read_app(name)
        if not r:
            out[name] = {"running": False}; continue
        if not r["window"]:
            out[name] = {"running": True, "window": False}; continue
        p = PARSERS[name](r["tree"])
        p["running"] = True; p["window"] = True
        p["front"]["court"] = court(p["front"])
        p["read_ms"] = int((time.time() - t0) * 1000)
        out[name] = p
    return out

def show(snap):
    for name, p in snap.items():
        if not p.get("running"):
            print(f"■ {name}: 没在运行"); continue
        if not p.get("window"):
            print(f"■ {name}: 在运行但没有窗口"); continue
        f = p["front"]
        print(f"■ {name}  ({p['read_ms']} ms)")
        print(f"   前台会话: {f['title'] or '（标题未读到）'}")
        print(f"   消息数 {f['messages']} · 最后一条: {f['last'] or '?'} · 判定 → {f['court']}")
        if p.get("replied_notice"):
            print(f"   提示条: {p['replied_notice']}")
        print(f"   会话列表 {len(p['conversations'])} 条:")
        for c in p["conversations"][:8]:
            extra = " · ".join(str(v) for k, v in c.items() if k != "title" and v)
            print(f"     - {c['title']}" + (f"  [{extra}]" if extra else ""))
        if len(p["conversations"]) > 8:
            print(f"     … 还有 {len(p['conversations'])-8} 条")

def key(snap):
    k = {}
    for name, p in snap.items():
        if p.get("window"):
            f = p["front"]; k[name] = (f["title"], f["court"], f["messages"], tuple((c.get("title"), c.get("status"), c.get("time")) for c in p["conversations"]))
    return k

if __name__ == "__main__":
    if not AXIsProcessTrusted():
        print("没有辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，把运行这个脚本的应用加进去。"); sys.exit(1)
    if "--json" in sys.argv:
        print(json.dumps(snapshot(), ensure_ascii=False, indent=1)); sys.exit()
    if "--watch" in sys.argv:
        prev = None
        print("监听中（Ctrl-C 停止）…")
        while True:
            snap = snapshot(); k = key(snap)
            if prev is None:
                show(snap)
            else:
                for name in k:
                    if k[name] != prev.get(name):
                        f = snap[name]["front"]
                        pf = prev.get(name)
                        print(time.strftime("%H:%M:%S"), f"{name}: {f['title']} → {f['court']}" + ("" if not pf or pf[1] == f['court'] else f"（原 {pf[1]}）"))
                        if pf and pf[1] in ("等 AI", "AI 生成中") and f["court"] == "轮到我":
                            print("           ↳ AI 回了，自动翻到「轮到我」")
                        # Claude 侧栏 Running→Idle
                        old = dict((c[0], c[1]) for c in pf[3]) if pf else {}
                        for c in snap[name]["conversations"]:
                            if c.get("status") == "Idle" and old.get(c["title"]) == "Running":
                                print("           ↳ 后台会话跑完了:", c["title"])
            prev = k
            time.sleep(4)
    show(snapshot())
