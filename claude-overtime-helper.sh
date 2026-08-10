#!/bin/bash
# ClaudeOvertime helper — root LaunchDaemon behind the ClaudeOvertime menu bar app.
#
# The menu bar app handles idle-sleep prevention itself (IOKit power
# assertion, no root needed). This daemon handles the one thing that
# requires root: `pmset disablesleep`, which keeps a MacBook running with
# the lid closed and no external display.
#
# Settings are read from the console user's ~/.config/claude-overtime.conf —
# the file the menu bar app writes. The console user is resolved on every
# poll, so the daemon works on any machine and across fast user switching.

POLL_SECS=5
LOG=/var/log/claude-overtime.log

# Keep in sync with kDefaultAgents in ClaudeOvertime/main.swift and status.sh.
DEFAULT_AGENTS="claude codex gemini copilot cursor-agent amp aider goose opencode crush qwen droid auggie"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

console_user_home() {
    local user
    user=$(stat -f%Su /dev/console 2>/dev/null)
    [ -z "$user" ] || [ "$user" = "root" ] && return 1
    dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
}

# Read KEY=VALUE from the config without sourcing it (the config is
# user-writable; we run as root, so never execute its contents).
cfg() {
    local v
    v=$(grep -E "^$1=" "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"')
    echo "${v:-$2}"
}

set_sleep_disabled() { pmset -a disablesleep "$1"; }

trap 'set_sleep_disabled 0; log "daemon stopping, sleep re-enabled"; exit 0' INT TERM

running_agents() {
    local found=() name agents
    agents=$(cfg AGENTS "$DEFAULT_AGENTS")
    for name in $agents $(cfg EXTRA_AGENTS ""); do
        pgrep -qx "$name" && found+=("$name")
    done
    echo "${found[*]}"
}

battery_pct() { pmset -g batt | grep -oE '[0-9]+%' | head -1 | tr -d '%'; }
on_ac_power() { pmset -g batt | grep -q "AC Power"; }

log "daemon started (poll ${POLL_SECS}s)"
state=""

while true; do
    home=$(console_user_home)
    CONFIG="${home:+$home/.config/claude-overtime.conf}"

    enabled=$(cfg ENABLED 1)
    lid=$(cfg LID_CLOSED 1)
    floor=$(cfg BATTERY_FLOOR 10)

    want="off"
    reason="no agents running"

    if [ "$enabled" = "1" ] && [ "$lid" = "1" ]; then
        agents=$(running_agents)
        if [ -n "$agents" ]; then
            want="on"
            reason="agents running: $agents"
            if ! on_ac_power; then
                pct=$(battery_pct)
                if [ -n "$pct" ] && [ "$floor" -gt 0 ] && [ "$pct" -le "$floor" ]; then
                    want="off"
                    reason="battery at ${pct}% (floor ${floor}%), yielding to sleep despite: $agents"
                fi
            fi
        fi
    else
        reason="disabled in settings (ENABLED=$enabled LID_CLOSED=$lid)"
    fi

    if [ "$want" != "$state" ]; then
        if [ "$want" = "on" ]; then
            set_sleep_disabled 1
            log "lid-closed sleep override ON — $reason"
        else
            set_sleep_disabled 0
            log "lid-closed sleep override off — $reason"
        fi
        state="$want"
    fi

    sleep "$POLL_SECS"
done
