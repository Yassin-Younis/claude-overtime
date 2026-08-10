#!/bin/bash
# Install the Claude Overtime root helper (lid-closed sleep override).
# Run with: sudo bash install.sh
#
# The menu bar app itself is installed separately, without sudo:
#   bash build.sh
# (Normally you never run this by hand — the app invokes it through the
#  macOS admin-password prompt whenever the helper is needed.)
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run me with sudo: sudo bash $0" >&2
    exit 1
fi

mkdir -p /usr/local/libexec
install -m 755 -o root -g wheel claude-overtime-helper.sh /usr/local/libexec/claude-overtime-helper.sh
install -m 644 -o root -g wheel com.claudeovertime.helper.plist /Library/LaunchDaemons/com.claudeovertime.helper.plist

# Reload if already installed; also clean up installs under legacy names
launchctl bootout system/com.claudeovertime.helper 2>/dev/null || true
launchctl bootout system/com.agentawake.helper 2>/dev/null || true
launchctl bootout system/com.sleepwalker.helper 2>/dev/null || true
launchctl bootout system/com.yassin.agent-awake 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.agentawake.helper.plist \
      /Library/LaunchDaemons/com.sleepwalker.helper.plist \
      /Library/LaunchDaemons/com.yassin.agent-awake.plist \
      /usr/local/libexec/agent-awake.sh \
      /usr/local/libexec/sleepwalker-helper.sh
launchctl bootstrap system /Library/LaunchDaemons/com.claudeovertime.helper.plist

sleep 2
if launchctl print system/com.claudeovertime.helper >/dev/null 2>&1; then
    echo "Claude Overtime helper installed and running."
    echo "Log: tail -f /var/log/claude-overtime.log"
else
    echo "Helper failed to start — check /var/log/claude-overtime.err" >&2
    exit 1
fi
