# CPU Sentinel

A lightweight native macOS menu bar app that detects orphan processes consuming excessive CPU or memory, and optionally kills them automatically.

Built with Swift using native `sysctl` APIs — no Electron, no dependencies, fully App Sandbox compatible.

## Why?

Dev tools like `next dev`, `vite`, `webpack-dev-server`, and others can sometimes become orphaned — their parent process dies but they keep running in the background, silently draining your CPU and memory. CPU Sentinel watches for these and alerts you (or kills them for you).

## Features

- **Orphan detection** — Identifies processes whose parent has died (PPID = 1) and are consuming resources
- **Smart filtering** — Only targets user-space dev processes, never touches system services or launched apps like Chrome, Slack, etc.
- **Three sensitivity profiles** — Relaxed, Balanced, Aggressive — no need to configure raw threshold values
- **Auto-kill mode** — Optionally terminate runaway processes automatically
- **Native notifications** — Get alerted when a runaway process is detected or killed
- **Watch list** — See processes approaching thresholds before they become runaways
- **Minimal footprint** — ~3MB, pure Swift, no runtime dependencies

## Sensitivity Profiles

| Profile | CPU Threshold | Memory | Uptime | Check Interval |
|---|---|---|---|---|
| Relaxed | >400% | >4 GB | >24h | 5 min |
| **Balanced** (default) | >200% | >2 GB | >1h | 30 sec |
| Aggressive | >100% | >1 GB | >30 min | 10 sec |

## How It Works

A process is considered a **runaway** when all of these are true:

1. It's an **orphan** (parent process ID = 1)
2. It's a **user process** (node, python, ruby, java, etc.) — not a system service
3. It's **not a launched app** (not from /Applications, not a .app bundle)
4. It exceeds CPU or memory thresholds for the selected sensitivity profile

## Build

Requires Xcode 15+ and macOS 13+.

```bash
git clone https://github.com/kburakf/cpu-sentinel.git
cd cpu-sentinel
open CPU\ Sentinel.xcodeproj
```

Build with **Cmd+B** in Xcode, or:

```bash
xcodebuild -project "CPU Sentinel.xcodeproj" -scheme "CPU Sentinel" -configuration Release build
```

## License

MIT
