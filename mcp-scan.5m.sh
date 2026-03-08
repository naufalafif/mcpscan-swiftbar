#!/bin/bash
# <bitbar.title>MCP Security Scanner</bitbar.title>
# <bitbar.version>1.0</bitbar.version>
# <bitbar.author>naufal</bitbar.author>
# <bitbar.desc>Shows MCP server security findings from Cisco mcp-scanner</bitbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# realpath may not exist on pre-Monterey macOS; fall back to $0
PLUGIN_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
CACHE_DIR="$HOME/.cache/mcp-scan"
CONFIG_FILE="$HOME/.config/mcp-scan/config"
CACHE_FILE="$CACHE_DIR/last-scan.json"
IGNORE_FILE="$CACHE_DIR/ignore.json"
LOCK_FILE="$CACHE_DIR/scan.lock"

# Load user config (SCAN_INTERVAL in minutes, default 30)
SCAN_INTERVAL=30
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
MAX_AGE=$(( SCAN_INTERVAL * 60 ))

mkdir -p "$CACHE_DIR"

# Initialize ignore file if missing
if [ ! -f "$IGNORE_FILE" ]; then
  echo '[]' > "$IGNORE_FILE"
fi

# --- Helper Functions ---

add_ignore() {
  local key="$1"
  python3 -c "
import json, sys
f = sys.argv[1]
key = sys.argv[2]
try:
    data = json.load(open(f))
    if not isinstance(data, list):
        data = []
except (json.JSONDecodeError, IOError):
    data = []
if key not in data:
    data.append(key)
    json.dump(data, open(f, 'w'), indent=2)
" "$IGNORE_FILE" "$key"
}

remove_ignore() {
  local key="$1"
  python3 -c "
import json, sys
f = sys.argv[1]
key = sys.argv[2]
try:
    data = json.load(open(f))
    if not isinstance(data, list):
        data = []
except (json.JSONDecodeError, IOError):
    data = []
data = [x for x in data if x != key]
json.dump(data, open(f, 'w'), indent=2)
" "$IGNORE_FILE" "$key"
}

# --- Handle Click Actions ---

if [ "$1" = "ignore" ] && [ -n "$2" ]; then
  add_ignore "$2"
  exit 0
fi

if [ "$1" = "unignore" ] && [ -n "$2" ]; then
  remove_ignore "$2"
  exit 0
fi

if [ "$1" = "rescan" ]; then
  rm -f "$CACHE_FILE" "$LOCK_FILE"
  exit 0
fi

if [ "$1" = "clear-ignores" ]; then
  echo '[]' > "$IGNORE_FILE"
  exit 0
fi

if [ "$1" = "set-interval" ] && [ -n "$2" ]; then
  mkdir -p "$(dirname "$CONFIG_FILE")"
  echo "SCAN_INTERVAL=$2  # Scan interval in minutes" > "$CONFIG_FILE"
  exit 0
fi

# --- Run Scan (with cache) ---

needs_scan=false
if [ ! -f "$CACHE_FILE" ]; then
  needs_scan=true
elif [ "$(( $(date +%s) - $(stat -f %m "$CACHE_FILE") ))" -gt "$MAX_AGE" ]; then
  needs_scan=true
fi

# Remove stale lock files older than 5 minutes
# Note: stat -f %m is BSD/macOS-specific (returns mtime as epoch)
if [ -f "$LOCK_FILE" ]; then
  lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE") ))
  if [ "$lock_age" -gt 300 ]; then
    rm -f "$LOCK_FILE"
  fi
fi

if $needs_scan && [ ! -f "$LOCK_FILE" ]; then
  touch "$LOCK_FILE"
  # Run scanner in background so SwiftBar stays responsive
  (
    if command -v timeout &>/dev/null; then
      SCANNER_CMD="timeout 120 mcp-scanner"
    else
      SCANNER_CMD="mcp-scanner"
    fi
    $SCANNER_CMD --analyzers yara --raw known-configs 2>/dev/null | python3 -c "
import sys
content = sys.stdin.read().strip()
idx = content.find('{')
if idx >= 0: print(content[idx:])
" > "$CACHE_FILE.tmp"
    if [ -s "$CACHE_FILE.tmp" ] && python3 -c "
import json, sys
json.load(open(sys.argv[1]))
" "$CACHE_FILE.tmp" 2>/dev/null; then
      mv "$CACHE_FILE.tmp" "$CACHE_FILE"
    else
      rm -f "$CACHE_FILE.tmp"
    fi
    rm -f "$LOCK_FILE"
  ) &>/dev/null &
  disown
fi

# --- Parse & Display ---

if [ ! -f "$CACHE_FILE" ]; then
  if [ -f "$LOCK_FILE" ]; then
    echo "🛡️ ~ | color=#666666"
    echo "---"
    echo "Scanning MCP servers... | color=#888888"
  else
    echo "🛡️ ?"
    echo "---"
    echo "No scan data yet | color=#888888"
    echo "Scan Now | bash='$PLUGIN_PATH' param1=rescan terminal=false refresh=true"
  fi
  exit 0
fi

# Parse results with Python
IS_SCANNING="false"
[ -f "$LOCK_FILE" ] && IS_SCANNING="true"
export PLUGIN_PATH SCAN_INTERVAL IS_SCANNING
python3 << 'PYEOF'
import json, os, sys, time

cache_file = os.path.expanduser("~/.cache/mcp-scan/last-scan.json")
ignore_file = os.path.expanduser("~/.cache/mcp-scan/ignore.json")
plugin_path = os.environ.get("PLUGIN_PATH", "")
scan_interval = int(os.environ.get("SCAN_INTERVAL", "30"))
is_scanning = os.environ.get("IS_SCANNING", "false") == "true"

try:
    with open(cache_file) as f:
        data = json.load(f)
except Exception:
    print("🛡️ ?")
    print("---")
    print("Failed to parse scan data | color=#888888")
    sys.exit(0)

try:
    with open(ignore_file) as f:
        ignored = json.load(f)
    if not isinstance(ignored, list):
        ignored = []
except Exception:
    ignored = []

def sanitize(s):
    """Strip pipes and escape quotes to prevent SwiftBar line-parsing issues."""
    return str(s).replace("|", "-").replace("'", "\\'")

# Collect all findings across config files
findings = []
total_tools = 0
servers_scanned = set()
configs_scanned = []

for config_path, tools in data.items():
    if not isinstance(tools, list) or not tools:
        continue
    configs_scanned.append(os.path.basename(config_path))
    for tool in tools:
        total_tools += 1
        server = tool.get("server_name", "unknown")
        servers_scanned.add(server)
        if not tool.get("is_safe", True):
            tool_name = tool.get("tool_name", "unknown")
            ignore_key = f"{server}:{tool_name}"
            severity = "UNKNOWN"
            threat_names = []
            for analyzer, result in tool.get("findings", {}).items():
                sev = result.get("severity", "UNKNOWN")
                if sev in ("HIGH", "CRITICAL"):
                    severity = sev
                elif sev == "MEDIUM" and severity not in ("HIGH", "CRITICAL"):
                    severity = sev
                elif sev == "LOW" and severity not in ("HIGH", "CRITICAL", "MEDIUM"):
                    severity = sev
                threat_names.extend(result.get("threat_names", []))
            findings.append({
                "server": server,
                "tool": tool_name,
                "severity": severity,
                "threats": threat_names,
                "description": tool.get("tool_description", ""),
                "key": ignore_key,
                "ignored": ignore_key in ignored,
                "config": os.path.basename(config_path),
            })

# Count active (non-ignored) issues
active = [f for f in findings if not f["ignored"]]
ignored_list = [f for f in findings if f["ignored"]]
high_count = sum(1 for f in active if f["severity"] in ("HIGH", "CRITICAL"))
med_count = sum(1 for f in active if f["severity"] == "MEDIUM")
low_count = sum(1 for f in active if f["severity"] == "LOW")

# Handle empty scan results (no configs or tools found)
if total_tools == 0:
    print("🛡️ ? | color=#888888")
    print("---")
    print("MCP Security Scanner | size=14 color=#ffffff")
    print("No MCP configs found | size=12 color=#888888")
    print("---")
    print(f"🔄 Scan Now | bash='{plugin_path}' param1=rescan terminal=false refresh=true")
    sys.exit(0)

# Menu bar icon — dimmed while scan is in progress
if is_scanning:
    colors = {"high": "#884444", "med": "#886622", "low": "#446633", "ok": "#336633"}
else:
    colors = {"high": "#ff4444", "med": "#ffaa00", "low": "#88aa00", "ok": "#44bb44"}

if high_count > 0:
    print(f"🛡️ {high_count} | color={colors['high']}")
elif med_count > 0:
    print(f"🛡️ {med_count} | color={colors['med']}")
elif low_count > 0:
    print(f"🛡️ {low_count} | color={colors['low']}")
else:
    print(f"🛡️ ✓ | color={colors['ok']}")

print("---")

# Summary header
cache_mtime = os.path.getmtime(cache_file)
age_min = int((time.time() - cache_mtime) / 60)
print("MCP Security Scanner | size=14 color=#ffffff")
next_scan = max(0, scan_interval - age_min)
print(f"Last scan: {age_min}m ago · next in {next_scan}m · {total_tools} tools · {len(servers_scanned)} servers | size=11 color=#888888")
configs_str = ", ".join(configs_scanned) if configs_scanned else "none found"
print(f"Configs: {configs_str} | size=11 color=#888888")
print("---")

# Active findings
if active:
    print(f"⚠️ Active Findings ({len(active)}) | size=13")
    sev_order = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}
    for f in sorted(active, key=lambda x: sev_order.get(x["severity"], 4)):
        sev = f["severity"]
        icon = {"CRITICAL": "🔴", "HIGH": "🔴", "MEDIUM": "🟡", "LOW": "🟢"}.get(sev, "⚪")
        color = {"CRITICAL": "#ff4444", "HIGH": "#ff4444", "MEDIUM": "#ffaa00", "LOW": "#88aa00"}.get(sev, "#888888")
        print(f"{icon} {sanitize(f['server'])}/{sanitize(f['tool'])} — {sev} | color={color} size=12")
        if f["threats"]:
            for t in f["threats"]:
                print(f"--{sanitize(t)} | size=11 color=#888888")
        if f["description"]:
            desc = sanitize(f["description"][:80])
            print(f"--{desc} | size=11 color=#666666")
        print(f"--Ignore this finding | bash='{plugin_path}' param1=ignore param2='{f['key']}' terminal=false refresh=true")
    print("---")
else:
    print("✅ No active findings | color=#44bb44")
    print("---")

# Ignored findings
if ignored_list:
    print(f"🔇 Ignored ({len(ignored_list)}) | size=13 color=#888888")
    for f in ignored_list:
        sev = f["severity"]
        print(f"--{sanitize(f['server'])}/{sanitize(f['tool'])} — {sev} | size=11 color=#888888")
        print(f"----Restore this finding | bash='{plugin_path}' param1=unignore param2='{f['key']}' terminal=false refresh=true")
    print("---")

# Safe servers summary
safe_servers = {}
for config_path, tools in data.items():
    if not isinstance(tools, list):
        continue
    for tool in tools:
        server = tool.get("server_name", "unknown")
        if tool.get("is_safe", True):
            safe_servers[server] = safe_servers.get(server, 0) + 1

if safe_servers:
    print("🟢 Safe Servers | size=13 color=#888888")
    for server, count in sorted(safe_servers.items()):
        print(f"--{sanitize(server)}: {count} tools ✓ | size=11 color=#44bb44")
    print("---")

# Scan interval submenu
intervals = [("5 minutes", 5), ("10 minutes", 10), ("15 minutes", 15),
             ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("6 hours", 360)]
print(f"⏱ Scan every {scan_interval}m | size=12")
for label, minutes in intervals:
    check = "✓ " if minutes == scan_interval else "    "
    print(f"--{check}{label} | bash='{plugin_path}' param1=set-interval param2={minutes} terminal=false refresh=true")
print("---")
# Actions
print(f"🔄 Scan Now | bash='{plugin_path}' param1=rescan terminal=false refresh=true")
print(f"🗑️ Clear All Ignores | bash='{plugin_path}' param1=clear-ignores terminal=false refresh=true")
print(f"📂 Open Ignore List | bash=/usr/bin/open param1='{ignore_file}' terminal=false")
PYEOF
