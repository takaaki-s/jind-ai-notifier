#!/usr/bin/env bash
# jind-ai-notifier — per-session "latest notification" stock for jind-ai (jin).
#
# This plugin doubles as the official example for jind-ai's plugin mechanism.
# One file, three modes:
#
#   1. Event listener (JIN_EVENT=status_changed) — keeps at most one pending
#      notification per session (task-complete / permission), drops the entry
#      when the session transitions to "thinking" (someone is attending it),
#      and fires a desktop notification whose click focuses the session.
#   2. Action (JIN_EVENT=action, from `jin plugin run jind-ai-notifier`) — opens a tmux
#      popup over the caller's own pane listing sessions with pending
#      notifications; picking one focuses it and consumes the entry.
#   3. Inner list UI (`notifier.sh --list <stock-file>`) — what runs inside the
#      popup. tmux spawns it fresh, so it inherits NO JIN_* env vars;
#      everything it needs travels on its command line (see mode_action).
#
# Conventions worth copying into your own plugin:
#   - Call back into jin via "${JIN_BIN:-jin}": the `jin` on PATH may be older
#     than the daemon that dispatched us.
#   - Fail open everywhere: a lost lock, a missing notify-send, a dead session
#     — log to stderr and exit 0. No notification is worth blocking a
#     session's status pipeline.

set -u

JIN="${JIN_BIN:-jin}"

# Plugin processes run with an allowlisted environment that strips
# XDG_STATE_HOME, so this always resolves to ~/.local/state for them. The
# popup inner process *does* inherit the user's real environment, which may
# disagree — that is why mode_action passes the resolved stock path explicitly
# and mode_list overrides STOCK with it.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/jind-ai-notifier"
STOCK="$STATE_DIR/stock.tsv"
LOCK_WAIT=5

ESC=$'\033'

# ---------------------------------------------------------------------------
# locking

lock_path() { printf '%s/stock.lock' "$(dirname "$STOCK")"; }

# with_lock <cmd...> — run <cmd...> under an exclusive flock on the stock.
# Waits up to LOCK_WAIT seconds, then gives up fail-open: the mutation is
# skipped (one lost notification beats eating into the plugin timeout).
# Without a flock command at all (stock macOS), run unserialized instead of
# not at all — a rare interleaved write beats a permanently empty list.
with_lock() {
  local lock
  mkdir -p "$(dirname "$STOCK")"
  if ! command -v flock >/dev/null 2>&1; then
    echo "notifier: flock not found; updating the stock without locking" >&2
    "$@"
    return
  fi
  lock=$(lock_path)
  {
    if ! flock -w "$LOCK_WAIT" 9; then
      echo "notifier: could not lock $lock within ${LOCK_WAIT}s; skipping (fail-open)" >&2
      return 0
    fi
    "$@"
  } 9>>"$lock"
}

# ---------------------------------------------------------------------------
# stock file: one line per session, 5 TSV fields
#   session_id <TAB> kind <TAB> epoch_ts <TAB> name <TAB> summary
# All writers run under with_lock and replace the file atomically (tmp + mv).

stock_upsert() {
  local line="$1" id tmp
  id="${line%%$'\t'*}"
  tmp="$STOCK.tmp.$$"
  {
    if [ -f "$STOCK" ]; then awk -F'\t' -v id="$id" '$1 != id' "$STOCK"; fi
    printf '%s\n' "$line"
  } >"$tmp"
  mv -f "$tmp" "$STOCK"
}

stock_delete_by_id() {
  local id="$1" tmp
  [ -f "$STOCK" ] || return 0
  tmp="$STOCK.tmp.$$"
  awk -F'\t' -v id="$id" '$1 != id' "$STOCK" >"$tmp"
  mv -f "$tmp" "$STOCK"
}

# Delete only the exact line we previously wrote. If a newer notification for
# the same session replaced it in the meantime, this is a no-op — a click on a
# stale desktop notification must not consume the newer entry.
stock_delete_exact() {
  local line="$1" tmp
  [ -f "$STOCK" ] || return 0
  tmp="$STOCK.tmp.$$"
  grep -vxF -- "$line" "$STOCK" >"$tmp" || true
  mv -f "$tmp" "$STOCK"
}

stock_snapshot() {
  if [ -f "$STOCK" ]; then cp -f "$STOCK" "$1"; else : >"$1"; fi
}

# ---------------------------------------------------------------------------
# helpers

# sanitize <text> — make an arbitrary string safe as a single TSV field:
# strip ANSI sequences, collapse tabs/newlines into single spaces, drop the
# remaining control characters, trim, and truncate to 120 characters
# (character-based, so multibyte text survives under a UTF-8 locale).
sanitize() {
  local s
  s=$(printf '%s' "$1" \
    | sed -e "s/${ESC}\[[0-9;]*[[:alpha:]]//g" \
    | tr -s '\t\n\r' '   ' \
    | tr -d '[:cntrl:]')
  s="${s#"${s%%[! ]*}"}"
  s="${s%"${s##*[! ]}"}"
  printf '%s' "${s:0:120}"
}

# session_name <id> — the session's Description via `jin session info` plain
# output (Key: Value lines). Falls back to the ID prefix; never fails.
session_name() {
  local id="$1" name
  name=$("$JIN" session info "$id" 2>/dev/null \
    | sed -n 's/^Description:[[:space:]]*//p' | head -n1) || name=""
  [ -n "$name" ] || name="${id:0:8}"
  sanitize "$name"
}

kind_label() {
  case "$1" in
    task-complete) printf 'done' ;;
    permission)    printf 'waiting for permission' ;;
    *)             printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# desktop notification (best-effort, three tiers)

desktop_notify() {
  local id="$1" kind="$2" name="$3" summary="$4" line="$5"
  local title action
  title="$name — $(kind_label "$kind")"

  if command -v notify-send >/dev/null 2>&1; then
    # With an action-capable daemon (dunst/mako/GNOME...) this blocks until
    # the notification is clicked or dismissed and prints the chosen action.
    if action=$(notify-send -A default=Open -- "$title" "$summary" 2>/dev/null); then
      if [ -n "$action" ]; then
        "$JIN" session focus "$id" >/dev/null 2>&1 || true
        with_lock stock_delete_exact "$line"
      fi
    else
      # Older notify-send without -A: plain notification, no click-to-focus.
      notify-send -- "$title" "$summary" >/dev/null 2>&1 || true
    fi
  elif [ "$(uname -s)" = "Darwin" ] && command -v terminal-notifier >/dev/null 2>&1; then
    # macOS: notify-send has no native equivalent; terminal-notifier gives us
    # click-to-focus. The -execute click runs in a separate process later, so
    # no entry is consumed here — the thinking transition takes care of it.
    terminal-notifier -title "$title" -message "${summary:-$(kind_label "$kind")}" \
      -execute "$(printf '%q ' "$JIN" session focus "$id")" >/dev/null 2>&1 || true
  else
    echo "notifier: no desktop notification command found; skipped" >&2
  fi
}

# ---------------------------------------------------------------------------
# mode 1: event listener

mode_listener() {
  local id="${JIN_SESSION_ID:-}"
  [ -n "$id" ] || return 0

  if [ "${JIN_STATUS:-}" = "thinking" ]; then
    # Someone typed into this session — it is attended. Drop its entry so the
    # list always means "sessions still waiting for a human".
    with_lock stock_delete_by_id "$id"
    return 0
  fi

  local kind="${JIN_NOTIFY_KIND:-}"
  case "$kind" in
    task-complete|permission) ;;
    *) return 0 ;;
  esac

  local summary=""
  if [ "$kind" = "task-complete" ]; then
    # Capture the last assistant message now: an unattended session's
    # transcript will not change afterwards. Not-yet-started sessions and
    # non-Claude agents fail here — fall back to a name-only row.
    summary=$("$JIN" session output "$id" 2>/dev/null) || summary=""
    summary=$(sanitize "$summary")
  fi

  local name ts line
  name=$(session_name "$id")
  ts=$(date +%s)
  line="$id"$'\t'"$kind"$'\t'"$ts"$'\t'"$name"$'\t'"$summary"

  # Stock first, notify second: if we are SIGTERM'd while waiting on the
  # notification click, the list is already correct.
  with_lock stock_upsert "$line"
  desktop_notify "$id" "$kind" "$name" "$summary" "$line"
}

# ---------------------------------------------------------------------------
# mode 2: action — open the list popup over the caller's own pane

mode_action() {
  local dir self inner
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  self="$dir/$(basename "${BASH_SOURCE[0]}")"
  # Pre-quote the whole inner command into ONE token: `jin pane popup -- ...`
  # joins trailing args with spaces, which would mangle paths with whitespace.
  # The env-assignment prefix hands JIN_BIN/JIN_SOCKET through to the popup
  # process, which inherits none of our JIN_* variables.
  inner=$(printf '%q ' env "JIN_BIN=$JIN" "JIN_SOCKET=${JIN_SOCKET:-}" \
    "$self" --list "$STOCK")
  exec "$JIN" pane popup --here --title " notifier " -- "$inner"
}

# ---------------------------------------------------------------------------
# mode 3: inner list UI (runs inside the tmux popup)

render_row() {
  local kind="$1" name="$2" summary="$3" line mark
  if [ "$kind" = "task-complete" ]; then
    mark="${ESC}[32m✓ done${ESC}[0m"
  else
    mark="${ESC}[33m⏸ wait${ESC}[0m"
  fi
  line="$mark  $name"
  [ -n "$summary" ] && line="$line  ${ESC}[2m$summary${ESC}[0m"
  printf '%s' "$line"
}

wait_key() {
  printf 'press any key to close'
  read -n1 -s -r || true
  printf '\n'
}

mode_list() {
  if [ -n "${1:-}" ]; then STOCK="$1"; fi

  # Snapshot under the lock, then talk to the daemon outside it: session info
  # round-trips must not extend the critical section. Entries arriving after
  # the snapshot are simply not shown this time — never deleted by mistake.
  local snap
  snap=$(mktemp "${TMPDIR:-/tmp}/notifier-list.XXXXXX")
  with_lock stock_snapshot "$snap"

  local rows=() dead=()
  local id kind ts name summary info fresh
  while IFS=$'\t' read -r id kind ts name summary; do
    [ -n "$id" ] || continue
    # </dev/null: a command inside a read loop must not eat the loop's stdin.
    if info=$("$JIN" session info "$id" </dev/null 2>/dev/null); then
      # Alive: refresh the display name from the same call (free freshness).
      fresh=$(printf '%s\n' "$info" \
        | sed -n 's/^Description:[[:space:]]*//p' | head -n1)
      [ -n "$fresh" ] && name=$(sanitize "$fresh")
      rows+=("$id"$'\t'"$kind"$'\t'"$ts"$'\t'"$name"$'\t'"$summary")
    else
      # Killed/deleted sessions vanish from the list automatically. Remember
      # the exact snapshot line: if a fresh notification replaced it while we
      # were querying (or the info failure was transient), deleting by exact
      # line is a no-op and the newer entry survives.
      dead+=("$id"$'\t'"$kind"$'\t'"$ts"$'\t'"$name"$'\t'"$summary")
    fi
  done <"$snap"
  rm -f "$snap"

  if [ "${#dead[@]}" -gt 0 ]; then
    local d
    for d in "${dead[@]}"; do with_lock stock_delete_exact "$d"; done
  fi

  if [ "${#rows[@]}" -eq 0 ]; then
    printf 'No pending notifications.\n'
    wait_key
    return 0
  fi

  # Newest first.
  local sorted
  sorted=$(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k3,3nr)

  local ids=() displays=()
  while IFS=$'\t' read -r id kind ts name summary; do
    ids+=("$id")
    displays+=("$(render_row "$kind" "$name" "$summary")")
  done <<<"$sorted"

  local idx=-1 i
  if command -v fzf >/dev/null 2>&1; then
    local menu="" choice
    for i in "${!ids[@]}"; do menu+="$i"$'\t'"${displays[$i]}"$'\n'; done
    choice=$(printf '%s' "$menu" | fzf --ansi --delimiter=$'\t' --with-nth=2 \
      --no-multi --prompt='notifier> ' \
      --header='enter: focus session / esc: close') || return 0
    idx="${choice%%$'\t'*}"
  else
    # No fzf: plain numbered menu.
    local n
    for i in "${!ids[@]}"; do
      printf ' %2d) %s\n' "$((i + 1))" "${displays[$i]}"
    done
    printf 'select # (q to close): '
    read -r n || return 0
    case "$n" in ''|q|Q) return 0 ;; esac
    case "$n" in
      *[!0-9]*) echo "invalid selection: $n" >&2; wait_key; return 0 ;;
    esac
    n=$((10#$n)) # base-10 always: a leading zero ("08") must not mean octal
    if [ "$n" -lt 1 ] || [ "$n" -gt "${#ids[@]}" ]; then
      echo "out of range: $n" >&2
      wait_key
      return 0
    fi
    idx=$((n - 1))
  fi

  local sel="${ids[$idx]}"
  if "$JIN" session focus "$sel"; then
    # Switching is what consumes an entry (merely viewing the list is not).
    with_lock stock_delete_by_id "$sel"
  else
    # Could not switch (TUI not running, ...): still unattended — keep it.
    echo "notifier: focus failed (is the TUI running? try: jin ui) — entry kept" >&2
    wait_key
  fi
}

# ---------------------------------------------------------------------------

main() {
  if [ "${1:-}" = "--list" ]; then
    shift
    mode_list "$@"
    return
  fi
  case "${JIN_EVENT:-}" in
    action)         mode_action ;;
    status_changed) mode_listener ;;
    *)              return 0 ;; # unknown events: ignore (compat contract)
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
