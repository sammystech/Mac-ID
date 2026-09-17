# Mac ID

Face unlock for macOS. A fork of [jonnyoo/glance](https://github.com/jonnyoo/glance) with a faster
recognition pipeline, a stronger face-embedding model, and a printed-photo check.

See [REPORT.md](REPORT.md) for what changed and the measurements behind each change.

## Build

```bash
xcodebuild -project src/glance.xcodeproj -scheme glance -configuration Release build
```

Signing is pinned in the project (automatic, team `G2LCW65DC4`). An Apple account must be signed in
to Xcode: the `keychain-access-groups` entitlement is profile-restricted, and without it the
Touch-ID-gated session key that protects the stored password fails with
`errSecMissingEntitlement`.

Do **not** build with `CODE_SIGN_IDENTITY="-"`. Ad-hoc signing makes the app's designated
requirement its binary hash, so every rebuild silently invalidates the Accessibility permission
while System Settings still shows it enabled.

## Release

```bash
./src/tools/release.sh 1.3
```

Builds, packages, signs the update with the EdDSA key, and regenerates `appcast.xml`. It stops
before publishing and prints the `gh release create` command.

Every release upload must include **all** the zips plus the appcast, not just the new one — the feed
points at `releases/latest/download/`, so older versions have to stay reachable from the newest
release.

### Distribution

The app is currently signed with an Apple Development certificate, which runs only on the
developer's own Macs. Shipping to anyone else needs a paid Apple Developer account, a Developer ID
Application certificate, and notarization. `release.sh` checks for this and warns.

### The update-signing key

The EdDSA private key lives in the login keychain, not in this repo. Back it up — losing it strands
every installed copy, because they will refuse any update not signed by it.

```bash
security find-generic-password -s "https://sparkle-project.org" -w
```
