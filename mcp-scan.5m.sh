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
SKILL_CACHE_FILE="$CACHE_DIR/last-skill-scan.json"
SKILL_LOCK_FILE="$CACHE_DIR/skill-scan.lock"

DEFAULT_SKILL_DIRS=(
  "$HOME/.cursor/skills"
  "$HOME/.cursor/rules"
  "$HOME/.claude/skills"
  "$HOME/.agents/skills"
  "$HOME/.codex/skills"
  "$HOME/.cline/skills"
  "$HOME/.opencode/skills"
  "$HOME/.continue/skills"
  "$HOME/.gemini/skills"
)

# Load user config (SCAN_INTERVAL in minutes, default 30)
SCAN_INTERVAL=30
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
MAX_AGE=$(( SCAN_INTERVAL * 60 ))

# Parse SKILL_DIRS (colon-separated) or fall back to defaults
if [ -n "${SKILL_DIRS:-}" ]; then
  IFS=':' read -ra SKILL_DIR_LIST <<< "$SKILL_DIRS"
else
  SKILL_DIR_LIST=("${DEFAULT_SKILL_DIRS[@]}")
fi

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
  rm -f "$LOCK_FILE" "$SKILL_LOCK_FILE"
  touch "$CACHE_DIR/force-rescan"
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

needs_mcp_scan=false
if [ ! -f "$CACHE_FILE" ]; then
  needs_mcp_scan=true
elif [ -f "$CACHE_DIR/force-rescan" ]; then
  needs_mcp_scan=true
elif [ "$(( $(date +%s) - $(stat -f %m "$CACHE_FILE") ))" -gt "$MAX_AGE" ]; then
  needs_mcp_scan=true
fi

needs_skill_scan=false
if command -v skill-scanner &>/dev/null; then
  if [ ! -f "$SKILL_CACHE_FILE" ]; then
    needs_skill_scan=true
  elif [ -f "$CACHE_DIR/force-rescan" ]; then
    needs_skill_scan=true
  elif [ "$(( $(date +%s) - $(stat -f %m "$SKILL_CACHE_FILE") ))" -gt "$MAX_AGE" ]; then
    needs_skill_scan=true
  fi
fi

# Remove stale lock files older than 5 minutes
# Note: stat -f %m is BSD/macOS-specific (returns mtime as epoch)
for lf in "$LOCK_FILE" "$SKILL_LOCK_FILE"; do
  if [ -f "$lf" ]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$lf") ))
    if [ "$lock_age" -gt 300 ]; then
      rm -f "$lf"
    fi
  fi
done

# Clear force-rescan before launching both background scans
if [ -f "$CACHE_DIR/force-rescan" ]; then
  rm -f "$CACHE_DIR/force-rescan"
fi

if $needs_mcp_scan && [ ! -f "$LOCK_FILE" ]; then
  touch "$LOCK_FILE"
  # Run MCP scanner in background so SwiftBar stays responsive
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

if $needs_skill_scan && [ ! -f "$SKILL_LOCK_FILE" ]; then
  touch "$SKILL_LOCK_FILE"
  # Run skill scanner in background
  (
    # Collect existing skill directories
    existing_dirs=()
    for d in "${SKILL_DIR_LIST[@]}"; do
      [ -d "$d" ] && existing_dirs+=("$d")
    done
    if [ ${#existing_dirs[@]} -gt 0 ]; then
      # Scan each directory, extract "results" array, merge into single list
      all_results="[]"
      for d in "${existing_dirs[@]}"; do
        result=$(skill-scanner scan-all "$d" --recursive --format json 2>/dev/null || echo "[]")
        all_results=$(python3 -c "
import json, sys, re
def clean(s):
    return re.sub(r'[\x00-\x1f\x7f]', ' ', s)
a = json.loads(clean(sys.argv[1]))
raw = json.loads(clean(sys.argv[2]))
# skill-scanner wraps results: {\"summary\": ..., \"results\": [...]}
if isinstance(raw, dict):
    b = raw.get('results', [])
elif isinstance(raw, list):
    b = raw
else:
    b = []
if not isinstance(a, list): a = []
print(json.dumps(a + b))
" "$all_results" "$result")
      done
      echo "$all_results" > "$SKILL_CACHE_FILE.tmp"
      if [ -s "$SKILL_CACHE_FILE.tmp" ] && python3 -c "
import json, sys
json.load(open(sys.argv[1]))
" "$SKILL_CACHE_FILE.tmp" 2>/dev/null; then
        mv "$SKILL_CACHE_FILE.tmp" "$SKILL_CACHE_FILE"
      else
        rm -f "$SKILL_CACHE_FILE.tmp"
      fi
    fi
    rm -f "$SKILL_LOCK_FILE"
  ) &>/dev/null &
  disown
fi

# --- Parse & Display ---

if [ ! -f "$CACHE_FILE" ] && [ ! -f "$SKILL_CACHE_FILE" ]; then
  if [ -f "$LOCK_FILE" ] || [ -f "$SKILL_LOCK_FILE" ]; then
    lock_age=0
    [ -f "$LOCK_FILE" ] && lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE") ))
    [ -f "$SKILL_LOCK_FILE" ] && {
      skill_lock_age=$(( $(date +%s) - $(stat -f %m "$SKILL_LOCK_FILE") ))
      [ "$skill_lock_age" -gt "$lock_age" ] && lock_age=$skill_lock_age
    }
    echo "🛡️ ~ | color=#666666"
    echo "---"
    echo "Scanning... (${lock_age}s) | color=#888888"
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
[ -f "$LOCK_FILE" ] || [ -f "$SKILL_LOCK_FILE" ] && IS_SCANNING="true"
export PLUGIN_PATH SCAN_INTERVAL IS_SCANNING SKILL_CACHE_FILE
python3 << 'PYEOF'
import json, os, sys, time

cache_file = os.path.expanduser("~/.cache/mcp-scan/last-scan.json")
skill_cache_file = os.environ.get("SKILL_CACHE_FILE", os.path.expanduser("~/.cache/mcp-scan/last-skill-scan.json"))
ignore_file = os.path.expanduser("~/.cache/mcp-scan/ignore.json")
plugin_path = os.environ.get("PLUGIN_PATH", "")
scan_interval = int(os.environ.get("SCAN_INTERVAL", "30"))
is_scanning = os.environ.get("IS_SCANNING", "false") == "true"

# Load MCP scan data
mcp_data = {}
try:
    with open(cache_file) as f:
        mcp_data = json.load(f)
except Exception:
    pass

# Load skill scan data (sanitize control chars from scanner output)
skill_results = []
try:
    import re
    with open(skill_cache_file) as f:
        raw = re.sub(r'[\x00-\x1f\x7f]', ' ', f.read())
    skill_results = json.loads(raw)
    if not isinstance(skill_results, list):
        skill_results = []
except Exception:
    skill_results = []

# If neither cache has data, show error
if not mcp_data and not skill_results:
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

sev_order = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}
sev_icon = {"CRITICAL": "🔴", "HIGH": "🔴", "MEDIUM": "🟡", "LOW": "🟢"}
sev_color = {"CRITICAL": "#ff4444", "HIGH": "#ff4444", "MEDIUM": "#ffaa00", "LOW": "#88aa00"}

# --- Parse MCP findings ---
mcp_findings = []
total_tools = 0
servers_scanned = set()
configs_scanned = []

for config_path, tools in mcp_data.items():
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
            mcp_findings.append({
                "server": server,
                "tool": tool_name,
                "severity": severity,
                "threats": threat_names,
                "description": tool.get("tool_description", ""),
                "key": ignore_key,
                "ignored": ignore_key in ignored,
                "config": os.path.basename(config_path),
            })

# --- Parse skill findings ---
skill_findings = []
skills_scanned = set()
safe_skills = set()

for entry in skill_results:
    skill_name = entry.get("skill_name") or entry.get("name") or "unknown"
    skills_scanned.add(skill_name)
    findings_data = entry.get("findings") or entry.get("rules_triggered") or []
    # Filter out INFO-only findings for display; keep MEDIUM+ as actionable
    actionable = [f for f in findings_data if isinstance(f, dict) and f.get("severity", "").upper() not in ("INFO", "")]
    if not actionable:
        safe_skills.add(skill_name)
    if isinstance(findings_data, list):
        for finding in findings_data:
            sev = finding.get("severity", "UNKNOWN").upper()
            if sev == "INFO":
                continue
            rule_id = finding.get("rule_id") or finding.get("id") or "UNKNOWN"
            title = finding.get("title") or finding.get("message") or rule_id
            category = finding.get("category", "")
            ignore_key = f"skill:{skill_name}:{rule_id}"
            skill_findings.append({
                "skill": skill_name,
                "rule_id": rule_id,
                "title": title,
                "severity": sev,
                "category": category,
                "key": ignore_key,
                "ignored": ignore_key in ignored,
            })

# --- Combined counts for menu bar ---
all_active_mcp = [f for f in mcp_findings if not f["ignored"]]
all_active_skill = [f for f in skill_findings if not f["ignored"]]
all_active = all_active_mcp + all_active_skill
all_ignored = [f for f in mcp_findings if f["ignored"]] + [f for f in skill_findings if f["ignored"]]

high_count = sum(1 for f in all_active if f["severity"] in ("HIGH", "CRITICAL"))
med_count = sum(1 for f in all_active if f["severity"] == "MEDIUM")
low_count = sum(1 for f in all_active if f["severity"] == "LOW")

# Handle empty scan results (no tools and no skills)
if total_tools == 0 and not skill_results:
    configs_found = sum(1 for v in mcp_data.values() if isinstance(v, list))
    if configs_found == 0:
        bar_line = "🛡️ ? | color=#888888"
        status_line = "No MCP configs found | size=12 color=#888888"
    else:
        bar_line = "🛡️ ✓ | color=#44bb44"
        status_line = f"✅ All clear — {configs_found} config{'s' if configs_found != 1 else ''} scanned, 0 threats | size=12 color=#44bb44"
    print(bar_line)
    print("---")
    print("MCP Security Scanner | size=14 color=#ffffff")
    print(status_line)
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
cache_mtime = 0
if os.path.exists(cache_file):
    cache_mtime = os.path.getmtime(cache_file)
if os.path.exists(skill_cache_file):
    skill_mtime = os.path.getmtime(skill_cache_file)
    cache_mtime = max(cache_mtime, skill_mtime)
age_min = int((time.time() - cache_mtime) / 60) if cache_mtime else 0
print("MCP Security Scanner | size=14 color=#ffffff")
next_scan = max(0, scan_interval - age_min)
summary_parts = [f"Last scan: {age_min}m ago · next in {next_scan}m"]
if total_tools:
    summary_parts.append(f"{total_tools} tools · {len(servers_scanned)} servers")
if skills_scanned:
    summary_parts.append(f"{len(skills_scanned)} skills")
print(f"{' · '.join(summary_parts)} | size=11 color=#888888")
configs_str = ", ".join(configs_scanned) if configs_scanned else "none found"
print(f"Configs: {configs_str} | size=11 color=#888888")
print("---")

# --- MCP Findings ---
if all_active_mcp:
    print(f"⚠️ MCP Findings ({len(all_active_mcp)}) | size=13")
    for f in sorted(all_active_mcp, key=lambda x: sev_order.get(x["severity"], 4)):
        sev = f["severity"]
        icon = sev_icon.get(sev, "⚪")
        color = sev_color.get(sev, "#888888")
        print(f"{icon} {sanitize(f['server'])}/{sanitize(f['tool'])} — {sev} | color={color} size=12")
        if f["threats"]:
            for t in f["threats"]:
                print(f"--{sanitize(t)} | size=11 color=#888888")
        if f["description"]:
            desc = sanitize(f["description"][:80])
            print(f"--{desc} | size=11 color=#666666")
        print(f"--Ignore this finding | bash='{plugin_path}' param1=ignore param2='{f['key']}' terminal=false refresh=true")
    print("---")

# --- Skill Findings ---
if all_active_skill:
    print(f"⚠️ Skill Findings ({len(all_active_skill)}) | size=13")
    for f in sorted(all_active_skill, key=lambda x: sev_order.get(x["severity"], 4)):
        sev = f["severity"]
        icon = sev_icon.get(sev, "⚪")
        color = sev_color.get(sev, "#888888")
        print(f"{icon} {sanitize(f['skill'])} — {sanitize(f['title'])} — {sev} | color={color} size=12")
        if f["category"]:
            print(f"--Category: {sanitize(f['category'])} | size=11 color=#888888")
        print(f"--Rule: {sanitize(f['rule_id'])} | size=11 color=#666666")
        print(f"--Ignore this finding | bash='{plugin_path}' param1=ignore param2='{f['key']}' terminal=false refresh=true")
    print("---")

# No active findings from either scanner
if not all_active_mcp and not all_active_skill:
    print("✅ No active findings | color=#44bb44")
    print("---")

# Ignored findings (combined)
if all_ignored:
    print(f"🔇 Ignored ({len(all_ignored)}) | size=13 color=#888888")
    for f in all_ignored:
        sev = f["severity"]
        if "server" in f:
            label = f"{sanitize(f['server'])}/{sanitize(f['tool'])}"
        else:
            label = f"{sanitize(f['skill'])}/{sanitize(f['rule_id'])}"
        print(f"--{label} — {sev} | size=11 color=#888888")
        print(f"----Restore this finding | bash='{plugin_path}' param1=unignore param2='{f['key']}' terminal=false refresh=true")
    print("---")

# Safe servers summary
safe_servers = {}
for config_path, tools in mcp_data.items():
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

# Safe skills summary
if safe_skills:
    print("🟢 Safe Skills | size=13 color=#888888")
    for skill in sorted(safe_skills):
        print(f"--{sanitize(skill)} ✓ | size=11 color=#44bb44")
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
