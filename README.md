<p align="center">
  <img src="docs/icon.png" alt="KeyBar icon: a padlock holding up a key" width="128" height="128">
</p>

<h1 align="center">KeyBar</h1>

<p align="center">
  <strong>Your API keys in the Keychain, ready for Claude Code without it ever seeing them.</strong><br>
  A free, open-source Mac menu bar app. Store a key once (Claude, Cloudflare, GitHub, Stripe, anything) and Claude Code uses it through KeyBar's MCP server: the key goes into one command as an environment variable, and any copy of it in the output is replaced with <code>[REDACTED]</code> before Claude sees it.
</p>

<p align="center">
  <a href="https://github.com/RossNicholson/keybar/releases/latest"><img src="https://img.shields.io/github/v/release/RossNicholson/keybar?label=release&color=C3C7F6&labelColor=232428" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-F6E2A4?labelColor=232428" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-6-F6C3B4?labelColor=232428" alt="Swift 6">
  <img src="https://img.shields.io/badge/signed%20%26%20notarized-yes-C2E6D6?labelColor=232428" alt="Signed and notarized">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-DCD2F0?labelColor=232428" alt="MIT licence"></a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
    <img src="docs/screenshot-light.png" alt="KeyBar's menu bar panel: a list of keys such as ANTHROPIC_API_KEY and CLOUDFLARE_API_TOKEN, each with its service, and show and copy buttons" width="300">
  </picture>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#connect-claude-code">Connect Claude Code</a> ·
  <a href="#features">Features</a> ·
  <a href="#security">Security</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="#build-from-source">Build</a>
</p>

---

## Install

```bash
brew tap RossNicholson/tap
brew trust --cask rossnicholson/tap/keybar
brew install --cask keybar
```

Homebrew 7 asks you to trust casks from other taps before installing them. On older versions of Homebrew, skip the `brew trust` line. The cask also puts the `keybar` command on your PATH.

**Requirements:** macOS 14 Sonoma or later, on Apple silicon or Intel.

### Updating

**Settings → Check for updates → Update KeyBar** quits, updates and reopens it. Or run `brew upgrade --cask keybar`. Installed from the DMG instead, Check for updates opens the latest release's page.

## Connect Claude Code

Open KeyBar, go to **Claude Code** and click **Connect Claude Code**. That adds KeyBar's MCP server to Claude Code for all your projects (user scope), using `claude mcp add` when it can find the `claude` command and editing `~/.claude.json` when it can't. If you leave the option on, it also adds a short marked note to `~/.claude/CLAUDE.md` telling Claude to check KeyBar before asking you for a key. **Disconnect** removes both.

New Claude Code sessions pick it up. Then just ask: *"deploy the site with my Cloudflare token"*. Claude lists the keys, runs `wrangler` with `$CLOUDFLARE_API_TOKEN` set, and never sees the token.

To connect by hand:

```bash
claude mcp add --scope user keybar -- /Applications/KeyBar.app/Contents/Helpers/keybar mcp
```

### The two tools

| Tool | What it does |
|---|---|
| `list_secrets` | The stored keys' names, services and kinds (e.g. `CLOUDFLARE_API_TOKEN: Cloudflare API token`). Never values. |
| `run_with_secrets` | Runs a shell command with the named keys set as environment variables. Returns the exit code, stdout and stderr, with every copy of a key replaced by `[REDACTED]`. |

Other MCP clients can use the same server; the activity log shows them by name.

## Find keys on this Mac

Already have keys in `.env` files? **Keys → Find keys** looks through the folders you choose for `.env` files (and `.mcp.json`), plus `export` lines in `~/.zshrc` and friends, the env of MCP servers in `~/.claude.json`, `~/.aws/credentials` and `~/.npmrc`. It skips `node_modules`, builds, hidden folders and example files, and only lists things that look like keys.

You tick what to import. The same value found in several projects becomes one key. When two projects use one name for different values, each gets its project's name in front (`SHOP_STRIPE_SECRET_KEY`, `BLOG_STRIPE_SECRET_KEY`), and you can rename them. Values KeyBar already has are marked as such.

Then, if you like, KeyBar takes the keys out of your `.env` files: each value becomes a reference to where it's stored, and other lines stay as they are.

```bash
STRIPE_SECRET_KEY=keybar:SHOP_STRIPE_SECRET_KEY
PORT=3000
```

## Run your own commands with keys: `keybar run`

```bash
keybar run -- npm run dev                                # keys from ./.env's keybar: lines
keybar run --key CLOUDFLARE_API_TOKEN -- wrangler deploy  # or name them
keybar run --key TOKEN=SHOP_API_TOKEN -- ./deploy.sh      # set a key under another name
keybar run --env-file .env.production -- npm start
```

KeyBar asks with Touch ID first and shows the command. One yes covers that exact command in that folder for 15 minutes; `keybar run` always asks, whatever Settings says about Claude, because its output isn't redacted. Other lines in the `.env` are set too, unless they're set already, the way dotenv does it, so tools that read `.env` themselves (Next.js, Vite, dotenv) keep working: the real values are already in the environment. Folder limits apply, and inside Claude Code `keybar run` refuses and points Claude to `run_with_secrets`.

## Features

- **Keychain storage.** Each key is its own item in your login keychain, named "KeyBar: NAME". Values are never written anywhere else.
- **Menu bar panel.** Find a key, show it or copy it. Showing and copying ask for Touch ID (or your Mac's password) first.
- **Clipboard care.** A copied key is wiped after 20 seconds (or 1 or 2 minutes), and is marked so clipboard managers skip it.
- **Activity log.** Every use, with the key, the program it ran, the folder, the exit code and whether anything was hidden, labelled *By Claude Code* or *By you*. Never values.
- **Folder limits.** Lock a key to the project folders that need it; a command run anywhere else is refused.
- **Refuses pasted keys.** A command with a key's actual value written into it is refused, so values don't end up in Claude's transcript.
- **Touch ID for Claude, too.** Before Claude Code uses a key, KeyBar asks with Touch ID and shows the command it wants to run. By default one yes covers the same keys from the same project for 15 minutes; choose every time, an hour or never in Settings.
- **Knows 468 services.** CLOUDFLARE_API_TOKEN is recognised as Cloudflare's API token, STRIPE_PUBLISHABLE_KEY as Stripe's publishable key. The list is built in, so recognising one never touches the network.
- **Recognises pasted keys.** Paste `sk-ant-…`, `ghp_…`, `sk_live_…` and dozens more and the name is filled in for you. Paste a whole `NAME=value` line and both fields fill.
- **Imports .env files.** Pick which lines to bring in, then delete the file. Or let [Find keys](#find-keys-on-this-mac) find them all.
- **Groups, order and notes.** Group keys by project (or leave them under their service), rename or ungroup a group, and put keys in your own order from the right-click menu. Search by name, service, group or note.
- **Archive.** File away a key you're not using: it stays in the Keychain but Claude can't see or use it until you restore it.
- **Menu bar dot.** A coral dot on the key while Claude Code isn't connected (you can turn it off).
- **Delete, even when stuck.** If the Keychain won't delete an item, KeyBar can take it off its list and leave it for Keychain Access.
- A window for managing it all, in light and dark mode.

<p align="center">
  <img src="docs/window-keys.png" alt="KeyBar's window, listing keys grouped by service and project" width="720">
</p>

## Security

**What KeyBar protects against:** keys sitting in plain-text `.env` files, shell history or chat transcripts; Claude reading a key's value; a command printing a key (as written, base64 including inside a Basic auth header, URL-encoded, hex, backwards or a long fragment of it); keys being used from the wrong project, even if Claude points a command at another project's folder.

**How it's built:**

- The MCP server is a small helper inside the app (`Contents/Helpers/keybar`). It asks the running app for keys over a Unix socket in `~/.keybar` that only your user can open.
- The app checks every caller's code signature and only answers its own helper, signed by the same Apple developer team. A script, or a copy of the helper signed by anyone else, is turned away. The helper checks the app's signature the same way before asking for anything, so nothing else can pose as KeyBar on the socket.
- Only the app reads the Keychain. The helper gets just the keys a command asked for, sets them as environment variables for that one command, and forgets them. A command that times out or is cancelled is stopped along with everything it started.
- Touch ID prompts name the app asking, the keys, the project and the command, time out after a few minutes, and only one waits at a time.

**What it can't stop.** Programs already running as you on your Mac are inside the boundary: one could start KeyBar's own helper just as Claude Code does. That's why *Ask before Claude uses a key* is on by default; with it set to *Never*, any of your programs can use your keys without asking. The command itself has the key. A command could change it before printing it (split it up, encrypt it) or send it over the network. Hiding it in the output is a safety net, not a sandbox. Claude Code asks you before running commands unless you've told it not to, so read what it wants to run, and use folder limits and *Ask before Claude uses a key* for the keys that matter most.

## Privacy

KeyBar makes no network requests of its own except checking for updates (Homebrew's index, or GitHub's latest release for a DMG install). No analytics, no crash reporter, no account. Service recognition is built in.

Local files, all readable only by you:

| What | Where |
|---|---|
| Key values | Your login keychain |
| Names, groups, notes, folders | `~/.keybar/index.json` |
| Activity log (no values) | `~/.keybar/activity.json` |
| The socket the helper uses | `~/.keybar/keybar.sock` |
| Claude Code connection | `~/.claude.json` and, if you choose, a marked note in `~/.claude/CLAUDE.md` |

## Uninstalling

In KeyBar, **Settings → Delete everything** removes every key from the Keychain and disconnects Claude Code. Then `brew uninstall --zap --cask keybar` removes the app and `~/.keybar`.

## Build from source

```bash
brew install xcodegen
make run          # builds a development copy and opens it
make test         # unit tests (keys in memory, never your Keychain)
make screenshots  # renders the UI with demo keys into build/screenshots
```

`make run` signs with a Developer ID so the app accepts its helper's signature. To build with your own certificate, change the team in `project.yml` and the Makefile: the app looks for its helper signed by the same team as itself.

Built with SwiftUI and the shared [HouseStyle](https://github.com/RossNicholson/mac-house-style) package, like [BrewDock](https://github.com/RossNicholson/brewdock), [ClawdBar](https://github.com/RossNicholson/clawdbar) and [Mop Up](https://github.com/RossNicholson/mop-up).

## Licence

MIT. KeyBar isn't affiliated with or endorsed by Anthropic. Claude and Claude Code are Anthropic's trademarks.
