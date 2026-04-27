#!/usr/bin/env bash
# audit-agent-health.sh — per-agent health summary scoped to the latest boot.
#
# Pino logs are append-only and persist across restarts, so a naive
# `grep ERROR logs/*.log` will surface stale crashes from yesterday's
# binary alongside genuinely-current issues. This script anchors the
# audit on each log's most recent "Running as agent" boot line and
# only counts ERROR / CRASH / RangeError / TypeError / Unauthorized
# lines that follow it.
#
# Usage:
#   ./scripts/audit-agent-health.sh           # summary table
#   ./scripts/audit-agent-health.sh -v        # also dump matching lines
#   ./scripts/audit-agent-health.sh sy main   # restrict to named agents

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/logs"

verbose=0
agents=()
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) verbose=1 ;;
    -h|--help)
      sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) agents+=("$arg") ;;
  esac
done

if [ ! -d "$LOGS_DIR" ]; then
  echo "logs dir not found: $LOGS_DIR" >&2
  exit 1
fi

# Build the list of logs to audit
log_files=()
if [ ${#agents[@]} -eq 0 ]; then
  while IFS= read -r f; do log_files+=("$f"); done < <(find "$LOGS_DIR" -maxdepth 1 -type f -name "*.log" | sort)
else
  for a in "${agents[@]}"; do
    f="$LOGS_DIR/${a}.log"
    if [ -f "$f" ]; then log_files+=("$f"); else echo "skip: $f not found" >&2; fi
  done
fi

if [ ${#log_files[@]} -eq 0 ]; then
  echo "no log files to audit" >&2
  exit 1
fi

printf '%-14s %-12s %-8s %-8s %-8s %s\n' "AGENT" "BOOT-LINE" "ERRORS" "CRASHES" "AUTH-401" "STATUS"
printf '%-14s %-12s %-8s %-8s %-8s %s\n' "----" "---------" "------" "-------" "--------" "------"

for log in "${log_files[@]}"; do
  agent="$(basename "$log" .log)"

  # Audit #18: zero-byte or mid-rotation logs were silently producing
  # "no-boot-marker" status that read as ambiguous. Distinguish empty/
  # tiny logs explicitly so they can't be confused with a real boot
  # failure or a missing-marker bug.
  bytes=$(stat -f%z "$log" 2>/dev/null || stat -c%s "$log" 2>/dev/null || echo 0)
  if [ "$bytes" -lt 256 ]; then
    printf '%-14s %-12s %-8s %-8s %-8s %s\n' "$agent" "n/a" "?" "?" "?" "log-empty(${bytes}b)"
    continue
  fi

  # Find the line number of the most recent boot marker. Pino emits
  # "Running as agent" once per specialist start. Main writes
  # "ClaudeClaw is running" near the end of its boot. mcp-server
  # writes "ClaudeClaw MCP server running on port" via plain stdout.
  #
  # Audit #14 fix: anchor on the Pino-pretty `): \x1b[36mMSG\x1b[39m$`
  # message-field structure so a task prompt body that happens to
  # contain literal "Running as agent" can't be mistaken for a boot
  # line. mcp-server doesn't use Pino pretty so its plain marker stays
  # unanchored, but its specific phrasing is unique enough to be safe.
  ESC=$(printf '\033')
  pino_boot_pattern="\\): ${ESC}\\[36m(Running as agent|ClaudeClaw is running)${ESC}\\[39m\$"
  mcp_boot_pattern='ClaudeClaw MCP server running'
  boot_line=$(grep -nE "($pino_boot_pattern)|$mcp_boot_pattern" "$log" 2>/dev/null | tail -1 | cut -d: -f1 || true)

  if [ -z "$boot_line" ]; then
    printf '%-14s %-12s %-8s %-8s %-8s %s\n' "$agent" "n/a" "?" "?" "?" "no-boot-marker"
    continue
  fi

  # Count post-boot errors. Use awk to slice the file from boot_line onward.
  post=$(awk -v start="$boot_line" 'NR >= start' "$log")
  errors=$(echo "$post"   | grep -cE 'ERROR|^\s*"type": ?"ApiError"' || true)
  crashes=$(echo "$post"  | grep -cE 'CRASH|RangeError|TypeError|UnhandledPromiseRejection' || true)
  auth401=$(echo "$post"  | grep -cE '401: ?Unauthorized|401\b' || true)

  status="ok"
  [ "$errors" -gt 0 ] && status="errors"
  [ "$crashes" -gt 0 ] && status="CRASHED"
  [ "$auth401" -gt 0 ] && status="${status}+auth"

  printf '%-14s %-12s %-8s %-8s %-8s %s\n' "$agent" "L$boot_line" "$errors" "$crashes" "$auth401" "$status"

  if [ "$verbose" -eq 1 ] && { [ "$errors" -gt 0 ] || [ "$crashes" -gt 0 ] || [ "$auth401" -gt 0 ]; }; then
    echo "$post" | grep -E 'ERROR|CRASH|RangeError|TypeError|401' | head -10 | sed 's/^/    /'
  fi
done
