#!/bin/bash
# Quick status check — no sudo needed.

CONFIG="$HOME/.config/claude-overtime.conf"
DEFAULT_AGENTS="claude codex gemini copilot cursor-agent amp aider goose opencode crush qwen droid auggie"

cfg() {
    local v
    v=$(grep -E "^$1=" "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"')
    echo "${v:-$2}"
}

AGENTS="$(cfg AGENTS "$DEFAULT_AGENTS") $(cfg EXTRA_AGENTS "")"

echo "App running:    $(pgrep -qx ClaudeOvertime && echo yes || echo NO)"
echo "Helper running: $(pgrep -qf /usr/local/libexec/claude-overtime-helper.sh && echo yes || echo "no (lid-closed unavailable)")"
echo "Sleep override: $(pmset -g | awk '/SleepDisabled/ {print ($2 == 1) ? "ACTIVE (Mac will not sleep, even lid-closed)" : "off (normal sleep)"}')"

found=""
for name in $AGENTS; do
    n=$(pgrep -x "$name" 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] && found+="  $name ($n process(es))\n"
done
if [ -n "$found" ]; then
    echo "Detected agents:"; printf "%b" "$found"
else
    echo "Detected agents: none"
fi

echo "Power: $(pmset -g batt | grep -oE "'.*'|[0-9]+%" | tr '\n' ' ')"
echo "Last actual sleep: $(sysctl -n kern.sleeptime | sed 's/.*} //')"
echo
echo "Recent helper log:"
tail -5 /var/log/claude-overtime.log 2>/dev/null || echo "  (no log yet — helper not installed)"
