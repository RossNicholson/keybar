# KeyBar

Your API keys in the macOS Keychain, ready for Claude Code without it ever seeing them.

KeyBar is a free, open-source menu bar app for macOS. Store a key once (Claude, Cloudflare, GitHub, Stripe, …)
and Claude Code can use it through KeyBar's MCP server: the key is set as an environment variable for one
command, and any copy of it in the output is replaced with `[REDACTED]` before Claude sees it.

Work in progress. Install instructions will be here with the first release:

```
brew install --cask rossnicholson/tap/keybar
```

MIT licence.
