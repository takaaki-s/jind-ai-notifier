**English** | [日本語](README.ja.md)

# jind-ai-notifier

A notification plugin for [jind-ai](https://github.com/takaaki-s/jind-ai)
(`jin`). It also doubles as the official example for jind-ai's plugin
mechanism — one manifest, one shell script, no build step.

## What it does

- Keeps at most **one pending notification per session**. A newer notification
  for the same session replaces the old one; history never piles up.
- Only two kinds are stocked: **task completion** (done) and **permission
  requests**. Errors are ignored.
- When a session transitions back to **thinking** (someone is attending it),
  its entry is dropped automatically — the list always means "sessions still
  waiting for a human".
- A key binding opens a tmux **popup listing the pending sessions**. Selecting
  one focuses that session and consumes its entry; merely viewing the list
  consumes nothing.
- Each event also fires a **desktop notification**; clicking it focuses that
  session directly.

## Requirements

- **jin (jind-ai)** — `main` including the v1.x plugin extensions from
  [PR #63](https://github.com/takaaki-s/jind-ai/pull/63), i.e. the next
  release or newer. The plugin relies on `jin pane popup --here`,
  `jin session focus`, and the `JIN_NOTIFY_KIND` / caller-tmux environment.
- **bash 4+**
- **flock** (util-linux) — serializes writes to the stock file. Where the
  command is missing (stock macOS), the plugin still works but updates the
  stock unlocked, with a warning on stderr — `brew install flock` restores
  serialization. Linux is the primary target; macOS is best-effort.
- **Linux**: `notify-send` plus an **action-capable** notification daemon
  (dunst / mako / GNOME Shell, ...) for click-to-focus.

Optional:

- **fzf** — a nicer, fuzzy-searchable list UI. Without it the popup falls back
  to a numbered prompt.
- **macOS**: `terminal-notifier` — enables click-to-focus (best-effort).
  Without it you still get a plain notification.

## Install

```bash
jin plugin install github.com/takaaki-s/jind-ai-notifier
```

jind-ai installs the plugin under the directory named by the manifest's
`name:` field — **`notifier`, not the repository name** — and that same name is
the verb you pass to `jin plugin run`. So every command below uses `notifier`,
e.g. `jin plugin run notifier`.

For development, symlink a local checkout in place instead:

```bash
jin plugin install --link .
```

## Usage

Bind a key in your everyday (outer) tmux to open the list:

```tmux
bind-key N run-shell "jin plugin run notifier"
```

Popup controls:

- **enter** — focus the selected session (and consume its entry).
- **esc / q** — close without changing anything (`esc` with fzf, `q` at the
  numbered prompt).

With fzf the list is fuzzy-searchable; without it, type the row number and
press enter.

Reading the list — one line per session, newest first:

- `✓ done` (green) — task complete. The row also shows a fragment of the last
  assistant message.
- `⏸ wait` (yellow) — waiting for permission.

Dead sessions (killed or deleted) are pruned from the list when it opens.
Clicking a desktop notification focuses that session directly, without opening
the popup.

## Customization

### Popup size

The plugin ships with `popup: { width: 70, height: 60 }` declared in
`jin-plugin.yaml` — the popup fills 70% × 60% of the terminal by default.
To use a different size, override it in your `jin` config under
`popups.plugins.notifier` (percentages of the terminal, 1–100 each):

```yaml
# ~/.config/jind-ai/config.yaml
popups:
  plugins:
    notifier:
      width: 80
      height: 50
```

User config wins over the manifest default. See jin's [Popup Sizes
guide](https://github.com/takaaki-s/jind-ai/blob/main/docs/tui-guide.md#popup-sizes)
for the full resolution chain.

## State / files

The stock lives at:

```
~/.local/state/jind-ai-notifier/stock.tsv
```

(The path is fixed: plugin processes run with an allowlisted environment that
strips `XDG_STATE_HOME`.) It is a plain TSV, one line per session. To clear
everything, just remove it — the plugin recreates it on the next event:

```bash
rm ~/.local/state/jind-ai-notifier/stock.tsv
```

## Known issues

- jind-ai's **built-in** desktop notifications still fire, so each
  notification appears twice. The built-in notifier is slated for removal; this
  plugin does not try to suppress it.

## As a plugin example

This repository is the reference example for jind-ai's plugin mechanism.
Everything lives in [`notifier.sh`](notifier.sh); a few conventions worth
copying into your own plugin:

- **One manifest, two trigger paths.** `main()` dispatches on `JIN_EVENT`:
  `status_changed` runs the event listener (`mode_listener`), and `action`
  (from `jin plugin run`) opens the popup (`mode_action`). No second script.
- **Popups don't inherit `JIN_*`.** tmux spawns the popup process fresh, so
  `mode_action` passes everything it needs on the command line: an
  env-assignment prefix (`env JIN_BIN=... JIN_SOCKET=...`) plus `printf '%q '`
  to collapse the whole inner command into a **single token** — `jin pane popup
  -- ...` re-joins trailing arguments with spaces, which would corrupt paths.
- **Always call back through `"${JIN_BIN:-jin}"`.** The `jin` on `PATH` may be
  older than the daemon that dispatched us (`JIN` is resolved once at the top
  of the script).
- **Fail open everywhere.** A lock not acquired within 5s (`with_lock`), a
  missing `notify-send` (`desktop_notify`), a dead session — each logs to
  stderr and returns 0. No notification is worth blocking a session's status
  pipeline.
- **State lives outside the plugin directory.** `~/.local/state/...`, not the
  plugin dir: `jin plugin update` replaces the directory wholesale, and the
  plugin's allowlisted environment strips `XDG_STATE_HOME` anyway (see the
  comment above `STATE_DIR`).

## Development

Tests use bats-core plus shellcheck; the test framework is vendored on demand
(cloned by CI and developers, not committed).

```bash
# lint
shellcheck notifier.sh test/stubs/jin

# tests: clone bats-core once, then run
git clone --depth 1 https://github.com/bats-core/bats-core.git test/lib/bats-core
test/lib/bats-core/bin/bats test
```

The tests point `JIN_BIN` at a stub (`test/stubs/jin`), so the whole
listener / consume flow runs without a live daemon — itself a demonstration of
the `"${JIN_BIN:-jin}"` contract. CI
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs exactly these two
steps on ubuntu-latest.

## License

MIT. See [LICENSE](LICENSE).
