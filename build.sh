#!/bin/bash
# Build and install the Claude Overtime menu bar app for the current user.
# No sudo needed. Requires Xcode or the Xcode Command Line Tools (swiftc).
#
#   bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install the Xcode Command Line Tools first:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi

APP="$HOME/Applications/ClaudeOvertime.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.claudeovertime.app.plist"

echo "Building ClaudeOvertime.app ..."
pkill -x ClaudeOvertime 2>/dev/null && sleep 1 || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O ClaudeOvertime/main.swift -o "$APP/Contents/MacOS/ClaudeOvertime"
cp ClaudeOvertime/Info.plist "$APP/Contents/Info.plist"
# Bundle the lid-closed helper so the app can self-install it via the
# native admin-password prompt, plus the menu bar icons.
cp claude-overtime-helper.sh com.claudeovertime.helper.plist install.sh \
   assets/menubar-active.png assets/menubar-idle.png \
   "$APP/Contents/Resources/"
codesign --force -s - "$APP"

# Migrate settings and clean up any prior installs under old names
[ -f "$HOME/.config/agent-awake.conf" ] && [ ! -f "$HOME/.config/claude-overtime.conf" ] && \
    cp "$HOME/.config/agent-awake.conf" "$HOME/.config/claude-overtime.conf"
pkill -x AgentAwake 2>/dev/null || true
pkill -x Sleepwalker 2>/dev/null || true
rm -rf "$HOME/Applications/AgentAwake.app" "$HOME/Applications/Sleepwalker.app"
rm -f "$HOME/Library/LaunchAgents/com.agentawake.app.plist" \
      "$HOME/Library/LaunchAgents/com.yassin.agentawake.app.plist" \
      "$HOME/Library/LaunchAgents/com.sleepwalker.app.plist"

# Start-at-login LaunchAgent
mkdir -p "$(dirname "$LAUNCH_AGENT")"
cat > "$LAUNCH_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.claudeovertime.app</string>
    <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ClaudeOvertime</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

open "$APP"
echo "Claude Overtime installed to $APP and running (look for the orange mascot in the menu bar)."
echo "If the lid-closed helper isn't installed yet, the app will prompt for it automatically."
