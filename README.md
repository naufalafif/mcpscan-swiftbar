# MCP Scan Bar

macOS menu bar plugin that shows MCP server security findings from [Cisco's mcp-scanner](https://github.com/cisco/mcp-scanner).

![menu bar](https://img.shields.io/badge/macOS-menu%20bar-black?style=flat-square) ![swiftbar](https://img.shields.io/badge/SwiftBar-plugin-blue?style=flat-square) ![lint](https://github.com/naufalafif/mcpscan-swiftbar/actions/workflows/lint.yml/badge.svg) ![security](https://github.com/naufalafif/mcpscan-swiftbar/actions/workflows/security.yml/badge.svg)

## What it shows

**Menu bar:**

```
🛡️ ✓          <- all clear (green)
🛡️ 2          <- 2 high/critical findings (red)
🛡️ 1          <- 1 medium finding (yellow)
```

**Dropdown:**

```
MCP Security Scanner
Last scan: 5m ago · next in 25m · 42 tools · 8 servers
Configs: claude_desktop_config.json, mcp.json

⚠️ Active Findings (2)
  🔴 someserver/tool_name — HIGH
    Data Exfiltration Attempt
    Ignore this finding
  🟡 another/tool — MEDIUM
    Prompt Injection
    Ignore this finding

🔇 Ignored (1)
  playwright/assert_response — LOW
    Restore this finding

🟢 Safe Servers
  context7: 2 tools ✓
  supabase: 15 tools ✓

🔄 Scan Now
🗑️ Clear All Ignores
📂 Open Ignore List
---
⏱ Scan Interval: every 30m
     5 minutes
     10 minutes
     15 minutes
  ✓  30 minutes
     1 hour
     2 hours
     6 hours
```

Finding colors: red (high/critical), yellow (medium), green (low).

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/naufalafif/mcpscan-swiftbar/main/setup.sh)
```

Or clone and run:

```bash
git clone git@github.com:naufalafif/mcpscan-swiftbar.git
cd mcpscan-swiftbar
bash setup.sh
```

## How the scan interval works

There are two timers at play:

| Timer | What it does | Default |
|-------|-------------|---------|
| **SwiftBar refresh** (filename `5m`) | Re-runs the script to update the display | Every 5 minutes |
| **Scan interval** (configurable) | How often mcp-scanner actually runs | Every 30 minutes |

The script runs every 5 minutes but only fires mcp-scanner when the cached results are older than the configured scan interval. Clicking **Scan Now** bypasses the cache immediately.

**To change the scan interval:** click the ⏱ menu at the bottom of the dropdown and pick an option (5m → 6h). The setting is saved to `~/.config/mcp-scan/config`.

## What the setup does

1. Installs [SwiftBar](https://github.com/swiftbar/SwiftBar) (if not present)
2. Installs [uv](https://github.com/astral-sh/uv) via Homebrew (if not present)
3. Installs [mcp-scanner](https://github.com/cisco/mcp-scanner) via `uv tool install`
4. Copies the SwiftBar plugin to `~/Plugins/SwiftBar/`
5. Initializes the ignore list at `~/.cache/mcp-scan/ignore.json`
6. Creates default config at `~/.config/mcp-scan/config` (scan interval: 30 min)
7. Launches SwiftBar

## Prerequisites

- macOS
- [Homebrew](https://brew.sh)
- Python 3 (comes with macOS)

## How it works

- Runs Cisco's `mcp-scanner` with YARA analysis on your known MCP config files (`claude_desktop_config.json`, `mcp.json`, etc.)
- Caches scan results at `~/.cache/mcp-scan/last-scan.json`
- Click **Scan Now** in the dropdown to trigger an immediate rescan
- Ignore individual findings — they persist across scans in `~/.cache/mcp-scan/ignore.json`

## Files

| File | Description |
|------|-------------|
| `setup.sh` | One-command installer |
| `mcp-scan.5m.sh` | SwiftBar plugin (reference copy — setup copies this to the plugin directory) |

## Uninstall

```bash
rm ~/Plugins/SwiftBar/mcp-scan.5m.sh
rm -rf ~/.cache/mcp-scan
rm -rf ~/.config/mcp-scan
brew uninstall --cask swiftbar  # optional
uv tool uninstall cisco-ai-mcp-scanner  # optional
```

## License

MIT
