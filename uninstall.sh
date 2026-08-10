#!/bin/bash
# Remove Claude Overtime completely (helper daemon + menu bar app).
# Run with: sudo bash uninstall.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run me with sudo: sudo bash $0" >&2
    exit 1
fi

# Root helper (current and legacy labels)
for label in com.claudeovertime.helper com.agentawake.helper com.sleepwalker.helper com.yassin.agent-awake; do
    launchctl bootout "system/$label" 2>/dev/null || true
done
rm -f /Library/LaunchDaemons/com.claudeovertime.helper.plist \
      /Library/LaunchDaemons/com.agentawake.helper.plist \
      /Library/LaunchDaemons/com.sleepwalker.helper.plist \
      /Library/LaunchDaemons/com.yassin.agent-awake.plist \
      /usr/local/libexec/claude-overtime-helper.sh \
      /usr/local/libexec/agent-awake.sh \
      /usr/local/libexec/sleepwalker-helper.sh
pmset -a disablesleep 0

# Menu bar app (user-level parts of whoever ran sudo)
TARGET_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
USER_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')
pkill -x ClaudeOvertime 2>/dev/null || true
rm -rf "$USER_HOME/Applications/ClaudeOvertime.app"
rm -f "$USER_HOME/Library/LaunchAgents/com.claudeovertime.app.plist" \
      "$USER_HOME/.config/claude-overtime.conf"

echo "Claude Overtime removed, sleep behavior restored to normal."
