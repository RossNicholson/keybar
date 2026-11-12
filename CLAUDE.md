# KeyBar

Open-source (MIT) macOS menu bar app that keeps API keys in the login keychain and lets Claude Code use
them through an MCP server without seeing their values. Ross's own take on Claude Keychain
(claudekeychain.app), matching its features first, then adding more. Same look as BrewDock, ClawdBar and
Mop Up via the shared HouseStyle package. GitHub: RossNicholson/keybar (public). Cask: `keybar` in
RossNicholson/homebrew-tap.

## Layout
- `KeyBar/`: the app. `AppDelegate` owns the status item, the panel, the window and the bridge.
  `Store/` (Keychain vault, index, activity log, service catalogue, .env parser, clipboard, Touch ID),
  `Bridge/BridgeServer.swift` (socket server + `BridgePolicy`, the rules), `ClaudeCode/ClaudeConnector`
  (registers the MCP server, CLAUDE.md note, test), `Views/` (panel, add form) and `Views/Window/`.
- `KeyBarHelper/`: the `keybar` tool, embedded at `KeyBar.app/Contents/Helpers/keybar`. `keybar mcp` is
  the stdio MCP server (`list_secrets`, `run_with_secrets`). Target is `KeyBarHelper` with product
  `keybar` and module `KeyBarHelper`: `KeyBar`/`keybar` collide on the case-insensitive disk otherwise.
- `Shared/`: compiled into both: the socket protocol (`Bridge.swift`) and `Redactor` / `SecretName`.

## How a use works
Helper → `~/.keybar/keybar.sock` (0600, dir 0700) → app checks euid + code signature (same team,
identifier `com.rossnicholson.KeyBar.helper`) → `BridgePolicy`: optional Touch ID approval, unknown
keys, folder limits, refuses commands containing a stored value → values back → helper runs `$SHELL -c`
with them set → redacts output (plain, base64 variants, URL-encoded, hex, reversed, 10-char fragments of
16+ char keys) → reports `finished` for the log.

## Commands
- `make run`: signed (Developer ID) dev build, opens it. Needs to run unsandboxed (keychain/signing).
- `make test`: unit tests, keys in memory. `TEST_RUNNER_KEYCHAIN_TESTS=1` adds a real-keychain test
  under a throwaway service name.
- `make screenshots` (demo data into build/screenshots), `make icon` (redraws the app icon from Mascot).
- `-demo YES` launch argument (Debug only): sample keys in memory.
- Release: `make release VERSION=x.y.z` (see RELEASING.md). Ask Ross before releasing.

## Gotchas
- Tests run inside the app as host and share its UserDefaults: restore any setting a test changes.
- Computer use can't target KeyBar until it's in /Applications; `osascript` System Events can click
  its menu bar item, and `screencapture` sees it.
- Don't connect Ross's real Claude Code from a dev build: it would register the build/dd path.

## Where we left off (2026-11-11)
- v0.1.0 in the repo, not released. All features of Claude Keychain plus: Touch ID approval for
  Claude's uses (on by default, 15 min, scoped to client + project + keys, prompt shows the command),
  client names in the log, redaction of reversed and embedded-base64 copies, 468 services, key-shape
  name suggestions, built-in (no network) service tiles.
- Feature parity checked against claudekeychain.app (site, llms-full.txt, changelog to 1.17) on
  2026-11-11: archive (Active/Archived), hand ordering, group rename/ungroup/move, force delete
  (`forget`), menu bar dot added. Deliberately left out: themes/accent/icon colours (HouseStyle look),
  favicon fetching (built-in tiles, no network), feedback nag (no promo).
- Independent security review done 2026-11-11; all 11 findings fixed: folder limits also checked
  against the helper's launch folder (`projectFolder`), helper verifies the app's signature
  (`CodeIdentity`) and keeps only the keys it asked for, Touch ID prompts time out (170 s) one at a time,
  literal-value refusals don't name the key or log the command, Claude config files never overwritten
  when unreadable (symlinks/permissions kept), process-group kill on timeout, MCP cancellation,
  translocated copies refuse to connect, pasted-value check reads the Keychain without UI.
- Verified: 36 tests (4 skip without env vars); end to end against the signed app in `-demo YES`
  (list, redaction incl. Basic auth, literal refusal, unknown key, timeout with no leftovers,
  cancel + ping while running, re-signed helper refused, impostor socket server refused); Release
  archive signs the helper correctly.
- For end-to-end runs use `-demo YES` (in-memory keys): keys added with `security add-generic-password`
  trigger a Keychain dialog when the app reads them. Turn approval off for scripted runs with
  `defaults write com.rossnicholson.KeyBar approvalSeconds -float 0` and delete it afterwards.
- Verified on screen 2026-11-11 with Ross (signed dev build, `-demo YES`): window, Active/Archived,
  right-click menu (archive/restore), menu bar dot, panel, add key from the panel (name suggested from
  a pasted token), Activity log, Touch ID reveal (Ross approved), Touch ID approval of a Claude use
  showing the command (Ross approved; repeat within 15 min went through without asking). Demo runs now
  ask for Touch ID like the real app; only tests skip it.
- Still to check after the first release: Connect against Ross's real Claude Code from the installed
  app (it was only checked in a temp HOME, to keep build paths out of his config).
- Release prep done 2026-11-12, waiting on Ross:
  - Tap: local branch `add-keybar` in /Volumes/t7ssd/Dev/homebrew-tap (cask + README row), not pushed.
    Merge and push it to main right before releasing (CI only bumps an existing cask).
  - Website: local branch `keybar` in /Volumes/t7ssd/Dev/RossNicholsonWebsite (keybar.html, keybar.css,
    images/keybar, home card, privacy, terms, support, sitemap). Merge to main after the release is out.
  - BrewDock: local branch `add-keybar` in /Volumes/t7ssd/Dev/brewdock lists KeyBar in Discover's
    "From the maker of BrewDock" (bundled KeyBarIcon). Merge, then ship it in the next BrewDock release.
  - The repo has no CI secrets yet. Auto mode blocked disabling the workflow and a local notarised
    build, so the release needs Ross: add the six secrets, then `make release VERSION=1.0.0`.
  - After release: add KeyBar to HouseStyle "More apps", connect Ross's real Claude Code from the
    installed app and check it.
