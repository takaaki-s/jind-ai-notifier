#!/usr/bin/env bats
#
# Tests for notifier.sh. Two techniques are used:
#
#   * Listen / list-popup / --list flows run the script as a fresh subprocess
#     (run_notifier) with JIN_BIN pointed at test/stubs/jin and XDG_STATE_HOME
#     inside BATS_TEST_TMPDIR — the same contract real plugin processes get.
#     Each invocation passes the manifest action verb (`listen` for event
#     dispatch, `--list` for the inner popup UI) as the first argument, exactly
#     as jin 0.8+ hands off through `actions[].entrypoint`.
#   * Pure helpers (stock_delete_exact) are exercised by sourcing the script in
#     an isolated `bash -c` so `set -u` never leaks into the bats shell.
#
# PATH is narrowed to the stub dir plus system bins so fzf and notify-send are
# absent (forcing the numbered-menu path and the no-notifier fallback), while a
# UTF-8 locale keeps sanitize's character-based truncation honest.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../notifier.sh"
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
  STUB="$STUB_DIR/jin"
  STATE_HOME="$BATS_TEST_TMPDIR/state"
  STOCK="$STATE_HOME/jind-ai-notifier/stock.tsv"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  SAFE_PATH="$STUB_DIR:/usr/bin:/bin"
}

# run_notifier [VAR=value ...] <script> [args...]
# Runs the target in a clean environment; extra assignments precede the script.
run_notifier() {
  run --separate-stderr env -i \
    PATH="$SAFE_PATH" \
    HOME="$BATS_TEST_TMPDIR" \
    TMPDIR="$BATS_TEST_TMPDIR" \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    JIN_BIN="$STUB" \
    XDG_STATE_HOME="$STATE_HOME" \
    STUB_LOG="$STUB_LOG" \
    "$@"
}

seed_stock() {
  mkdir -p "$(dirname "$STOCK")"
  printf '%s\n' "$@" >"$STOCK"
}

field() { awk -F'\t' -v n="$1" 'NR==1{print $n}' "$STOCK"; }

# --- 正常系 --------------------------------------------------------------

@test "V-001: task-complete stocks one 5-field row (id/kind/epoch/name/summary)" {
  run_notifier \
    JIN_SESSION_ID=sess-1 \
    JIN_NOTIFY_KIND=task-complete STUB_OUTPUT="the last reply" \
    "$SCRIPT" listen
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STOCK")" -eq 1 ]
  [ "$(awk -F'\t' 'NR==1{print NF}' "$STOCK")" -eq 5 ]
  [ "$(field 1)" = "sess-1" ]
  [ "$(field 2)" = "task-complete" ]
  [[ "$(field 3)" =~ ^[0-9]+$ ]]
  [ -n "$(field 4)" ]
  [ "$(field 5)" = "the last reply" ]
}

@test "V-002: permission stocks a row with an empty summary" {
  run_notifier \
    JIN_SESSION_ID=sess-2 JIN_NOTIFY_KIND=permission \
    "$SCRIPT" listen
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' 'NR==1{print NF}' "$STOCK")" -eq 5 ]
  [ "$(field 2)" = "permission" ]
  [ -z "$(field 5)" ]
}

@test "V-003: thinking transition consumes only the matching session" {
  run_notifier JIN_SESSION_ID=sess-A \
    JIN_NOTIFY_KIND=task-complete STUB_OUTPUT="A done" "$SCRIPT" listen
  run_notifier JIN_SESSION_ID=sess-B \
    JIN_NOTIFY_KIND=permission "$SCRIPT" listen
  [ "$(wc -l <"$STOCK")" -eq 2 ]

  run_notifier JIN_SESSION_ID=sess-A \
    JIN_STATUS=thinking "$SCRIPT" listen
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STOCK")" -eq 1 ]
  ! grep -q $'^sess-A\t' "$STOCK"
  grep -q $'^sess-B\t' "$STOCK"
}

@test "V-004: repeated events on one session keep only the latest row" {
  run_notifier JIN_SESSION_ID=sess-4 \
    JIN_NOTIFY_KIND=task-complete STUB_OUTPUT="first" "$SCRIPT" listen
  run_notifier JIN_SESSION_ID=sess-4 \
    JIN_NOTIFY_KIND=permission "$SCRIPT" listen
  [ "$(wc -l <"$STOCK")" -eq 1 ]
  [ "$(field 2)" = "permission" ]
}

@test "V-005: --list renders newest first and marks done vs permission" {
  seed_stock \
    $'sess-old\ttask-complete\t100\tOld\tGAMMA-OLD' \
    $'sess-mid\tpermission\t200\tMid\t' \
    $'sess-new\ttask-complete\t300\tNew\tALPHA-NEW'
  run_notifier "$SCRIPT" --list "$STOCK" <<<""
  [ "$status" -eq 0 ]
  new_ln=$(printf '%s\n' "$output" | grep -n 'ALPHA-NEW' | head -n1 | cut -d: -f1)
  old_ln=$(printf '%s\n' "$output" | grep -n 'GAMMA-OLD' | head -n1 | cut -d: -f1)
  [ -n "$new_ln" ]
  [ -n "$old_ln" ]
  [ "$new_ln" -lt "$old_ln" ]
  printf '%s\n' "$output" | grep -q 'done'
  printf '%s\n' "$output" | grep -q 'wait'
}

# --- 準正常系 ------------------------------------------------------------

@test "V-009: number input focuses and consumes the chosen entry" {
  seed_stock \
    $'s-keep\tpermission\t100\tKeep\t' \
    $'s-pick\ttask-complete\t200\tPick\tPICKME'
  run_notifier "$SCRIPT" --list "$STOCK" <<<"1"
  [ "$status" -eq 0 ]
  grep -q 'session focus s-pick' "$STUB_LOG"
  ! grep -q $'^s-pick\t' "$STOCK"
  grep -q $'^s-keep\t' "$STOCK"
}

@test "V-009: a zero-padded number (08) selects in base 10, not octal" {
  local i lines=()
  for i in $(seq 1 9); do
    lines+=("$(printf 's-%d\tpermission\t%d\tName%d\t' "$i" "$((i * 100))" "$i")")
  done
  seed_stock "${lines[@]}"
  # Newest first: row 8 is ts=200 → s-2.
  run_notifier "$SCRIPT" --list "$STOCK" <<<"08"
  [ "$status" -eq 0 ]
  grep -q 'session focus s-2' "$STUB_LOG"
  ! grep -q $'^s-2\t' "$STOCK"
}

@test "V-009: q closes the list without consuming anything" {
  seed_stock \
    $'s-keep\tpermission\t100\tKeep\t' \
    $'s-pick\ttask-complete\t200\tPick\tPICKME'
  run_notifier "$SCRIPT" --list "$STOCK" <<<"q"
  [ "$status" -eq 0 ]
  ! grep -q 'session focus' "$STUB_LOG"
  [ "$(wc -l <"$STOCK")" -eq 2 ]
}

@test "V-010: session output failure falls back to an empty summary, exit 0" {
  run_notifier JIN_SESSION_ID=sess-10 \
    JIN_NOTIFY_KIND=task-complete STUB_OUTPUT_FAIL=1 "$SCRIPT" listen
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STOCK")" -eq 1 ]
  [ "$(field 2)" = "task-complete" ]
  [ -z "$(field 5)" ]
}

@test "V-011 (CLI): focus failure keeps the entry and reports an error" {
  seed_stock $'s-fail\ttask-complete\t100\tFail\tKEEPME'
  run_notifier STUB_FOCUS_FAIL=1 "$SCRIPT" --list "$STOCK" <<<"1"
  [ "$status" -eq 0 ]
  grep -q 'session focus s-fail' "$STUB_LOG"
  grep -q $'^s-fail\t' "$STOCK"
  [[ "$stderr" == *"focus failed"* ]]
}

@test "V-012: a missing notification command still stocks and exits 0" {
  run_notifier JIN_SESSION_ID=sess-12 \
    JIN_NOTIFY_KIND=task-complete STUB_OUTPUT="hi" "$SCRIPT" listen
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STOCK")" -eq 1 ]
  [[ "$stderr" == *"no desktop notification"* ]]
}

# --- 異常系 --------------------------------------------------------------

@test "V-013: a dead session is hidden from --list and pruned from the stock" {
  seed_stock \
    $'id-alive\ttask-complete\t200\tAlive\tALIVESUM' \
    $'id-dead\ttask-complete\t100\tDead\tDEADSUM'
  run_notifier STUB_INFO_FAIL=id-dead "$SCRIPT" --list "$STOCK" <<<""
  [ "$status" -eq 0 ]
  [[ "$output" == *ALIVESUM* ]]
  [[ "$output" != *DEADSUM* ]]
  grep -q $'^id-alive\t' "$STOCK"
  ! grep -q $'^id-dead\t' "$STOCK"
}

@test "V-015: a held lock fails open after ~5s without touching the stock" {
  seed_stock $'existing\tpermission\t100\tExisting\t'
  before=$(cat "$STOCK")
  lock="$STATE_HOME/jind-ai-notifier/stock.lock"
  ready="$BATS_TEST_TMPDIR/lock-ready"

  flock "$lock" -c "touch '$ready'; sleep 8" &
  holder=$!
  for _ in $(seq 1 100); do [ -f "$ready" ] && break; sleep 0.05; done

  start=$SECONDS
  run_notifier JIN_SESSION_ID=late \
    JIN_NOTIFY_KIND=task-complete STUB_OUTPUT="x" "$SCRIPT" listen
  elapsed=$((SECONDS - start))

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [ "$elapsed" -ge 4 ]
  [ "$(cat "$STOCK")" = "$before" ]
  [[ "$stderr" == *"could not lock"* ]]
}

# --- 境界値 --------------------------------------------------------------

@test "V-016: an empty stock shows the no-pending message" {
  run_notifier "$SCRIPT" --list "$STOCK" <<<"x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No pending notifications"* ]]
  ! grep -q 'session focus' "$STUB_LOG" 2>/dev/null
}

@test "V-017: control chars, ANSI, and long multibyte text sanitize to one <=120-char field" {
  raw=$'col1\tcol2\n\033[31mred\033[0m'"$(printf 'あ%.0s' $(seq 1 200))"
  run_notifier JIN_SESSION_ID=sess-17 \
    JIN_NOTIFY_KIND=task-complete STUB_OUTPUT="$raw" "$SCRIPT" listen
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STOCK")" -eq 1 ]
  [ "$(awk -F'\t' 'NR==1{print NF}' "$STOCK")" -eq 5 ]

  summary=$(field 5)
  chars=$(printf '%s' "$summary" | LC_ALL=C.UTF-8 wc -m)
  [ "$chars" -le 120 ]
  [ "$summary" = "$(printf '%s' "$summary" | tr -d '[:cntrl:]')" ]
}

@test "V-018: stock_delete_exact is a no-op once the line was overwritten" {
  mkdir -p "$(dirname "$STOCK")"
  run env -i PATH="$SAFE_PATH" HOME="$BATS_TEST_TMPDIR" \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    bash -c '
      source "$1"
      STOCK="$2"
      stock_upsert "$3"
      stock_upsert "$4"
      stock_delete_exact "$3"
    ' _ "$SCRIPT" "$STOCK" \
    $'idX\ttask-complete\t100\tName\tOLD-A' \
    $'idX\tpermission\t200\tName\t'
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STOCK")" -eq 1 ]
  [ "$(field 2)" = "permission" ]
  [ "$(field 3)" = "200" ]
}
