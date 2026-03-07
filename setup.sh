#!/bin/bash
set -euo pipefail

# ============================================================
# MCP Security Scanner Menu Bar Setup
# Installs SwiftBar + mcp-scanner plugin
# ============================================================

GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "${GREEN}[+]${RESET} $1"; }
warn() { echo -e "${YELLOW}[!]${RESET} $1"; }
err()  { echo -e "${RED}[x]${RESET} $1"; exit 1; }

PLUGIN_DIR="$HOME/Plugins/SwiftBar"
CACHE_DIR="$HOME/.cache/mcp-scan"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Prerequisites ---
command -v brew &>/dev/null || err "Homebrew is required. Install from https://brew.sh"
command -v python3 &>/dev/null || err "Python 3 is required"

# --- Install SwiftBar ---
if [ -d "/Applications/SwiftBar.app" ]; then
    log "SwiftBar already installed"
else
    log "Installing SwiftBar..."
    brew install --cask swiftbar
fi

# --- Resolve plugin directory ---
# Respect existing SwiftBar plugin directory if already configured
EXISTING_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [ -n "$EXISTING_DIR" ] && [ -d "$EXISTING_DIR" ]; then
    PLUGIN_DIR="$EXISTING_DIR"
    log "Using existing SwiftBar plugin directory: $PLUGIN_DIR"
else
    mkdir -p "$PLUGIN_DIR"
    defaults write com.ameba.SwiftBar PluginDirectory "$PLUGIN_DIR" 2>/dev/null || true
    log "Plugin directory set to: $PLUGIN_DIR"
fi

# --- Install uv ---
if command -v uv &>/dev/null; then
    log "uv already installed"
else
    log "Installing uv..."
    brew install uv
fi

# --- Install mcp-scanner ---
if command -v mcp-scanner &>/dev/null; then
    log "mcp-scanner already installed"
else
    log "Installing mcp-scanner via uv..."
    if ! uv tool install --python 3.13 cisco-ai-mcp-scanner 2>/dev/null; then
        warn "Python 3.13 unavailable, trying without version pin..."
        uv tool install cisco-ai-mcp-scanner || err "Failed to install mcp-scanner"
    fi
fi

# --- Copy plugin ---
PLUGIN_FILE="$PLUGIN_DIR/mcp-scan.30m.sh"
if [ -f "$SCRIPT_DIR/mcp-scan.30m.sh" ]; then
    cp "$SCRIPT_DIR/mcp-scan.30m.sh" "$PLUGIN_FILE"
else
    log "Downloading plugin..."
    if ! curl -fsSL "https://raw.githubusercontent.com/naufalafif/mcp-scan-bar/main/mcp-scan.30m.sh" -o "$PLUGIN_FILE"; then
        err "Failed to download plugin (check URL or network)"
    fi
    # Validate downloaded file is a bash script, not an error page
    if ! head -1 "$PLUGIN_FILE" | grep -q '^#!/bin/bash'; then
        rm -f "$PLUGIN_FILE"
        err "Downloaded file is not a valid bash script"
    fi
fi
chmod +x "$PLUGIN_FILE"
log "Plugin installed to $PLUGIN_FILE"

# --- Initialize ignore file ---
mkdir -p "$CACHE_DIR"
if [ ! -f "$CACHE_DIR/ignore.json" ]; then
    echo '[]' > "$CACHE_DIR/ignore.json"
    log "Initialized ignore list at $CACHE_DIR/ignore.json"
else
    log "Ignore list already exists"
fi

# --- Smoke test ---
if ! mcp-scanner --help &>/dev/null; then
    warn "mcp-scanner installed but --help failed; plugin may not work correctly"
fi

# --- Launch SwiftBar ---
log "Starting SwiftBar..."
killall SwiftBar 2>/dev/null || true
sleep 1
open -a SwiftBar

echo ""
echo -e "${BOLD}Setup complete!${RESET}"
echo ""
echo "  Menu bar: Shield icon + finding count + severity color"
echo "  Dropdown: Active findings, ignored items, safe servers, actions"
echo ""
echo "  Plugin scans every 30 minutes."
echo "  Click 'Scan Now' in the dropdown to trigger immediately."
echo ""
