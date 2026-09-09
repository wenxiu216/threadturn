# Threadturn

**Whose turn is it?** A macOS menu bar app that keeps track of every conversation you have open across ChatGPT, Claude and Grok, and tells you which ones are waiting on *you*.

You juggle several AI apps. You send a prompt in one, switch to another, and twenty minutes later you have no idea which replies you never read and which threads you never answered. Threadturn watches the desktop clients you already have open and sorts every conversation into one of two courts:

- **Your turn** — the AI replied and you haven't done anything with it.
- **Waiting on AI** — you sent something and the reply hasn't landed yet.

When a reply lands, the thread flips to *Your turn* and you get a notification. Mark it done when you're finished. If the AI speaks again later, the thread comes back on its own.

## Zero input

There is nothing to type and nothing to pick. Threadturn reads the windows of the AI apps through macOS Accessibility, looks at who sent the last message, and decides for you. You keep using ChatGPT, Claude and Grok exactly as before.

## What it does *not* do

- No accounts. It never logs in to anything.
- No scraping, no cookies, no network requests to the AI vendors.
- No reading of conversations you don't already have open on screen.

It only reads the accessibility tree of windows that are already on your Mac, the same way a screen reader would. Everything is stored locally in `~/Library/Application Support/Threadturn/`.

## Supported apps

| App | How a thread is detected |
|---|---|
| ChatGPT (macOS app) | "You said" / "ChatGPT said" message headings, current chat from the sidebar |
| Claude (macOS app) | Message headings, plus per-session *Running / Idle* state in the sidebar, so background sessions are tracked too |
| Grok (macOS app) | Message roles in the transcript, sidebar previews and the "replied" banner |

Each parser lives in `Sources/Threadturn/AX.swift`. When a vendor changes its UI, that is the file to fix.

## Build

Requires macOS 13+ and the Xcode Command Line Tools (Swift 5.9+). No Xcode project needed.

```bash
git clone https://github.com/wenxiu216/threadturn.git
cd threadturn
./build.sh            # builds and installs ~/Applications/Threadturn.app
open ~/Applications/Threadturn.app
```

On first launch macOS asks for Accessibility permission. Grant it in **System Settings → Privacy & Security → Accessibility**.

### If the toggle is on but the menu bar still shows `!`

macOS keys the Accessibility grant to the app's bundle identifier and code signature. If either changed since the grant (for example after the bundle id was renamed), the switch in System Settings can look enabled while the running app is still denied. Close System Settings, then reset the stale record and relaunch:

```bash
tccutil reset Accessibility com.threadturn.app && pkill -x Threadturn; open ~/Applications/Threadturn.app
```

Approve the prompt that appears. The app also offers a **Request permission** button in its popover whenever it detects the grant is missing.

### Keeping the permission across rebuilds

Ad-hoc signed builds get a new signature every time, and macOS revokes the Accessibility grant when the signature changes. Run this once to create a local self-signed certificate; `build.sh` will use it automatically from then on:

```bash
./make-cert.sh
```

## Keyboard and controls

Click the menu bar icon (the number is how many threads are your turn). Each thread has **Open** (activates the app and jumps to that conversation), **Later** (snooze), **Done**, and **Ignore** (hide until the AI says something new).

## Repository layout

```
Sources/Threadturn/
  AX.swift      Accessibility reader and the three app parsers
  Model.swift   thread state machine and on-disk store
  UI.swift      SwiftUI popover
  main.swift    menu bar item, polling loop, notifications
Assets/         icon source script and generated icon set
docs/engine.py      standalone Python probe used to validate the parsers
docs/prototype.html the original interaction prototype (browser only)
```

## License

MIT
