# Portside

A macOS menu bar app for local dev servers: see everything listening on
localhost, stop it, restart it, open it in the browser.

Native SwiftUI (`MenuBarExtra`), no dependencies, one binary.

Made by [Thomas Drach](https://github.com/tdrach) at
[Subtract](https://subtract.design). Builds are signed with Thomas's
Apple Developer ID, so macOS will show his name — same person, same
project.

## What it does

One list. Every server Portside has ever seen, each row start/stop-able.

- **Detects** every listening TCP server via `lsof`, with the process's working
  directory resolved — so `node :5173` shows up as *flatland*, not a mystery pid.
- **Auto-saves** anything new it detects (with a usable working directory):
  name from the folder, command guessed from `package.json`
  (`npm`/`pnpm`/`yarn`/`bun`, `dev`/`start`/`serve` scripts — falls back to the
  process's actual command line), port from detection. Once seen, restarting it
  is one click forever.
- Per row: start (`play`), stop (`stop`), open `http://localhost:PORT`
  (`globe` or click the row), and ⋯ for Edit / View log / Reveal / Copy URL /
  Start-or-Stop server / Remove. Removing a running server also stops it, so
  the row doesn't instantly re-adopt.
- Servers with no working directory to restart from (Docker-style daemons) show
  while running and disappear when stopped — there's no recipe to save.
- **Logs**: every managed server's output goes to
  `~/Library/Application Support/Portside/logs/<name>.log` (row menu → View Log).
- Menu bar icon shows a count of live servers.
- **Memory** per row: the resident footprint of the server's whole process
  tree, amber past 2 GB and red past 6 GB — long-lived `next dev` servers
  leak, and the row tells you when a restart is due.

## Install

```sh
brew install --cask subtractdotdesign/tap/portside
```

Or download the latest `.dmg` from
[Releases](https://github.com/subtractdotdesign/portside/releases), drag Portside to
Applications, launch it. Signed with a Developer ID and notarized by Apple, so it opens
without Gatekeeper warnings — and the notarization ticket is stapled to
both the app and the disk image, so it validates offline.

Move it to /Applications rather than running it from the disk image:
Gatekeeper's app translocation can otherwise break launch-at-login.

**Updating:** `brew upgrade --cask portside`, or use ⋯ → Check for
updates in the app, which opens the latest release.

**Upgrading from a build you compiled yourself before 0.2.0?** Those were
ad-hoc signed, and macOS keys some state to code-signing identity. Your
saved servers, projects, and logs carry over untouched, but you may be
re-prompted for folder access on the first scan, and if you had
launch-at-login enabled you should toggle it off and on once so macOS
re-registers the login item under the new identity.

## Build from source

```sh
make install   # builds dist/Portside.app, copies to /Applications, opens it
```

Other targets: `make app` (build the bundle), `make dmg` (unsigned disk
image), `make release` (signed + notarized + stapled DMG — needs a Developer
ID and `make notarize-setup`), `make run` (dev run from terminal), `make
scan` (headless one-shot scan, prints the table), `make clean`.

Without a Developer ID certificate in your keychain, builds are ad-hoc
signed — fine locally, not distributable.

Servers are stored in `~/Library/Application Support/Portside/servers.json`.

## How stopping works

- Servers Portside started live in their **own process group**, so Stop kills
  the whole tree (npm → node → esbuild workers): SIGTERM, then SIGKILL after 3s
  if anything in the group is still alive.
- Servers Portside didn't start are re-verified as still-listening at signal
  time (a scan snapshot can be seconds stale), then SIGTERMed, with a longer
  10s grace before a re-verified SIGKILL — external processes may be
  databases mid-write and get more patience than our own dev servers.
- A row only ever signals processes it can **attribute**: a run's own process
  group, a port match corroborated by working directory, or a directory match.
  Another project squatting a saved server's port is never killed through
  that row — it surfaces as its own row instead.

## Safety guarantees

- Portside writes **only** inside `~/Library/Application Support/Portside/`
  (servers.json, tombstones.json, logs). It never writes into a repo; project
  files (package.json etc.) are read-only probes — non-blocking, symlink-
  refusing, size-capped, so a planted FIFO or link can't hang or redirect it.
- Log files are 0600, opened `O_NOFOLLOW`, rotated at 5 MB (one `.old`
  generation), and deleted when their server is removed.
- **Remove sticks**: removed recipes are tombstoned, so supervised servers
  (nodemon, launchd KeepAlive) that respawn under new pids don't resurrect
  rows. Adding the same directory + command back via Add server clears the
  tombstone.
- A corrupt/hand-edited `servers.json` is set aside as `servers.json.corrupt`,
  never silently overwritten.
- Single instance enforced with a file lock (covers `swift run` and the
  `.app` equally), so two copies can't double-adopt.
- Restart commands built from a foreign process's argv are shell-quoted
  per-argument and only persisted when argv[0] actually resolves to an
  executable — proctitle-rewritten junk (puma, pm2) becomes an ephemeral row
  instead of a broken saved entry.

## Notes & caveats

- Commands execute via `/bin/zsh -c` for stable syntax, but the
  **environment** is captured once at startup from your login shell run
  interactively — so nvm/mise/asdf/volta PATHs work even when they're set up
  in `~/.zshrc`. Homebrew and version-manager bins are appended as a fallback.
- Detected-server filtering: ephemeral ports (≥ 49152) and known app daemons
  (Figma, Raycast, Adobe, Cursor/Code helpers, rapportd, …) are hidden — edit
  `PortScanner.denylist` to taste. Saved servers bypass both filters, so a
  high-port server you saved still tracks correctly.
- Auto-adoption skips app internals and tool state: system paths, `~/Library`,
  `$HOME` itself, hidden directories, `node_modules`, `.app` bundles, temp
  dirs. Those show while running and vanish when stopped.
- "Launch at Login" only works when running from the `.app` bundle
  (`make install`), not `swift run`.

## Tests

`swift test` — 125 tests covering the lsof/NUL parser (including field-forgery
attempts), KERN_PROCARGS2 parsing, shell-quoting round-trips through a real
zsh, claiming precedence, adoption boundaries, store durability (corruption,
migration, symlink quarantine, permissions), launcher process-group semantics
(real spawn + group-kill integration), project aggregation and ordered-start
readiness probing, and a live end-to-end scan against a socket the test
itself binds.

## Projects

Group servers that belong together (api + frontend + worker) and run them as
one unit. A project takes a single row: its chip aggregates member status and
converges toward running, and clicking the row unfurls the members inline.
Optionally start members **in order**, each one waiting until the previous
server's port actually accepts connections.

Add a server to a project from its ⋯ menu, or from the Project field in the
add/edit dialog. Removing a project only ungroups its servers.

## Ideas for later

- Inline log tail in the popover
- Per-server env vars
- Global hotkey to toggle the popover
