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
- **2026-11-12: `keybar run` asks for Touch ID every time** (Ross's call): no approval is ever reused, whatever
  Settings or a key's own rule says. Closes the gap where a kept approval could be reused by something that
  edited the command's script or got past the Claude Code check. On main, waiting for release as 1.4.6.
- **2026-11-12: fixes from a code review, RELEASED in 1.4.5.** .env Import
  skips `keybar:` pointers (they overwrote real keys); moving keys to iCloud copies all first, deletes last
  (a failure moves nothing); a proxied key whose proxy can't be set up is refused, never handed over (the
  bridge checks `proxied`, not `usesProxy`); Touch ID prompt squeezes spaces, strips bidi/control
  characters and shows a long command's start and end; `keybar run` checks the process ancestry for
  Claude Code (`ClaudeCodeCheck`), needs a terminal, and an approval only covers that tty (still beatable
  by a detached process reading the user's tty, so not airtight); proxy rejects negative/huge lengths
  (crash); Test and the proxy only send a key to a service when its name names exactly one
  (`ServiceCatalog.destination`); a copy without iCloud leaves the sync setting and index.json alone;
  .env swap writes through symlinks; one-word file keys are redacted whole. Tests: `ReviewFixTests`.
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
- Paused 2026-11-12 by Ross ("stop for now"). Release prep is done, waiting on Ross to add the six
  CI secrets (or allow a local notarised release; auto mode blocked that and disabling the workflow).
  Prepared branches, pushed to GitHub but not merged:
  - homebrew-tap `add-keybar`: the cask + README row.
  - RossNicholsonWebsite `keybar`: keybar.html/.css, images/keybar, home card, privacy, terms,
    support, sitemap.
  - brewdock `add-keybar`: KeyBar in Discover's featured list (bundled KeyBarIcon). Tests pass.
  - README's Install section says 1.0.0 isn't out yet; remove that at release.
  The order of steps is in RELEASING.md "The first release".
