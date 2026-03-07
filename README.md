# MCP Scan Bar

macOS menu bar plugin that shows MCP server security findings from [Cisco's mcp-scanner](https://github.com/cisco/mcp-scanner).

![menu bar](https://img.shields.io/badge/macOS-menu%20bar-black?style=flat-square) ![swiftbar](https://img.shields.io/badge/SwiftBar-plugin-blue?style=flat-square) ![lint](https://github.com/naufalafif/mcp-scan-bar/actions/workflows/lint.yml/badge.svg) ![security](https://github.com/naufalafif/mcp-scan-bar/actions/workflows/security.yml/badge.svg)

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
Last scan: 5m ago · 42 tools · 8 servers
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
```

Finding colors: red (high/critical), yellow (medium), green (low).

## Quick Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/naufalafif/mcp-scan-bar/main/setup.sh)
```

Or clone and run:

```bash
git clone git@github.com:naufalafif/mcp-scan-bar.git
cd mcp-scan-bar
bash setup.sh
```

## What the setup does

1. Installs [SwiftBar](https://github.com/swiftbar/SwiftBar) (if not present)
2. Installs [uv](https://github.com/astral-sh/uv) via Homebrew (if not present)
3. Installs [mcp-scanner](https://github.com/cisco/mcp-scanner) via `uv tool install`
4. Copies the SwiftBar plugin to `~/Plugins/SwiftBar/`
5. Initializes the ignore list at `~/.cache/mcp-scan/ignore.json`
6. Launches SwiftBar

## Prerequisites

- macOS
- [Homebrew](https://brew.sh)
- Python 3 (comes with macOS)

## How it works

- Runs Cisco's `mcp-scanner` with YARA analysis on your known MCP config files (`claude_desktop_config.json`, `mcp.json`, etc.)
- Caches scan results at `~/.cache/mcp-scan/last-scan.json`
- The plugin refreshes every **30 minutes** (re-scans if cache is stale)
- Click **Scan Now** in the dropdown to trigger an immediate rescan
- Ignore individual findings — they persist across scans in `~/.cache/mcp-scan/ignore.json`

## Files

| File | Description |
|------|-------------|
| `setup.sh` | One-command installer |
| `mcp-scan.30m.sh` | SwiftBar plugin (reference copy — setup copies this to the plugin directory) |

## Uninstall

```bash
rm ~/Plugins/SwiftBar/mcp-scan.30m.sh
rm -rf ~/.cache/mcp-scan
brew uninstall --cask swiftbar  # optional
uv tool uninstall cisco-ai-mcp-scanner  # optional
```

## License

MIT
