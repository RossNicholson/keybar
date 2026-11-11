# Releasing KeyBar

Releases are automated. **One command:**

```
make release VERSION=1.2.3
```

That bumps the version, commits, tags `v1.2.3`, and pushes. GitHub Actions then
builds, **signs**, **notarizes**, **staples**, publishes the GitHub release, and
bumps the Homebrew cask — then re-downloads the asset and verifies its sha256 +
notarization before declaring success.

**Don't** run `scripts/release.sh --publish` by hand: pushing a tag already
triggers CI, which is the single source of truth. To build a local notarized
test DMG, use `make dmg` (or `scripts/release.sh` with no arguments).

## Why this is hard to get wrong
- `make release` refuses to run on a dirty tree, off `main`, with a malformed
  version, or a tag that already exists.
- CI fails fast with a clear message if any required secret is missing.
- CI aborts if the pushed tag doesn't match the version that was actually built.
- Notarization is a hard gate — an un-notarized build cannot ship.
- The publish step is idempotent (safe to re-run after a transient failure).
- After publishing, CI re-downloads the asset and checks its sha256 + notarization.

## Required repo secrets
Settings → Secrets and variables → Actions. The same six are used by BrewDock,
ClawdBar, Mop Up and KeyBar:

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | base64 of the Developer ID Application `.p12` |
| `P12_PASSWORD` | the `.p12` export password |
| `NOTARY_API_KEY_P8_BASE64` | base64 of the App Store Connect `.p8` |
| `NOTARY_KEY_ID` | the notary key's ID |
| `NOTARY_ISSUER_ID` | the notary issuer ID |
| `TAP_PUSH_TOKEN` | fine-grained PAT, `contents:write` on `RossNicholson/homebrew-tap` only. One token, "Homebrew tap push (all apps)", is shared by BrewDock, ClawdBar, Mop Up and KeyBar; it expires 17 Oct 2027 |

## The first release
1. Add the six secrets above to `RossNicholson/keybar` (the same values as the other apps).
2. Copy `docs/keybar.rb` to `Casks/keybar.rb` in `RossNicholson/homebrew-tap` and push it. CI only
   bumps an existing cask, so it has to be there before the first `make release`.
3. `make release VERSION=1.0.0`.
4. Add KeyBar to HouseStyle's "More apps by Ross" (`HouseMacApp`), tag it, and bump the apps.

## What the release checks for KeyBar
On top of notarization, `scripts/release.sh` refuses to ship unless the `keybar` helper in
`Contents/Helpers` is Developer ID signed, has the identifier `com.rossnicholson.KeyBar.helper`
and the hardened runtime, and the app passes `codesign --verify --deep --strict`. The app only
answers a helper signed that way, so a release without it would leave Claude Code locked out.
