# harness-container

Run [Claude Code](https://code.claude.com/docs) sandboxed with your project available for full
development and a network policy you choose per run:

- **Linux (and Windows via WSL 2):** a **rootless Podman** container, sections 1–6 below.
- **macOS, for Mac and Xcode projects:** **no containers**: macOS's built-in Seatbelt sandbox
  confines Claude and everything it runs, natively. See [macOS native sandbox](#macos-native-sandbox).

[![Verify Claude Code sandbox](https://github.com/nycnighthawk/harness-container/actions/workflows/verify-sandbox.yml/badge.svg)](https://github.com/nycnighthawk/harness-container/actions/workflows/verify-sandbox.yml)

| File | Purpose |
|---|---|
| `Containerfile` | Dev image: Debian + Claude Code (native installer), Node, Python, build tools, non-root `claude` user |
| `claude-sandbox.sh` | Launcher: mounts the project, picks auth + network mode, applies hardening |
| `proxy/` | Tiny allowlist proxy (tinyproxy) used by `--net restricted` |
| `allowlist/claude.txt` | Hosts Claude Code needs (always allowed in restricted mode) |
| `allowlist/dev.txt` | GitHub + npm/PyPI/crates/Go/Debian (`--allow dev`) |
| `check-rootless.sh` | Checks host prerequisites and prints fixes |
| `tests/run-tests.sh` | End-to-end verification suite (also run in CI) |

## 1. Set up rootless Podman (once)

```bash
# Fedora / RHEL
sudo dnf install -y podman
# Ubuntu 24.04+ / Debian 12+  (Podman >= 4.3 required; Ubuntu 22.04 is too old)
sudo apt install -y podman uidmap passt netavark aardvark-dns fuse-overlayfs dbus-user-session

# subordinate UID/GID ranges for your user
grep "^$USER:" /etc/subuid /etc/subgid || {
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
  podman system migrate; }

# optional: allow --memory/--cpus limits for rootless containers
sudo mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | \
  sudo tee /etc/systemd/system/user@.service.d/delegate.conf
sudo systemctl daemon-reload   # then log out/in

./check-rootless.sh            # PASS/WARN/FAIL with fixes
```

Never run `podman` with `sudo` for this setup. On macOS/Windows use `podman machine init && podman machine start`.

## 2. Build

```bash
podman build -t claude-sandbox .
podman build -t claude-sandbox-proxy proxy/          # auto-built on first restricted run
# customize: --build-arg NODE_MAJOR=20 --build-arg EXTRA_APT="golang postgresql-client"
ln -s "$PWD/claude-sandbox.sh" ~/.local/bin/claude-sandbox
```

## 3. Develop

```bash
cd ~/code/my-app
claude-sandbox                          # Claude Code with ./ mounted at /workspace
claude-sandbox --yolo                   # --dangerously-skip-permissions (inside the sandbox only)
claude-sandbox --shell                  # bash in the same environment
claude-sandbox -p 3000 -p 8080:80       # publish dev-server ports on 127.0.0.1
claude-sandbox --gitconfig              # mount ~/.gitconfig read-only
claude-sandbox --project ../other --ro  # other project, read-only
claude-sandbox -- -p "fix the failing tests"   # args after -- go to claude
```

The project is mounted at the **same absolute path** inside the container as on the host, so
Claude's per-directory sessions, trust and memory stay separate per project. Files created in the
sandbox are owned by **you** on the host (`--userns=keep-id`). The container has no
capabilities, `no-new-privileges`, no `sudo`, and never sees `~/.ssh` or cloud credentials.

## 4. Network modes

| Flag | Reachable | Use for |
|---|---|---|
| `--net full` (default) | Everything | Normal dev; required for `-p` |
| `--net restricted` | Only Claude's hosts, via allowlist proxy | Untrusted repos, preventing exfiltration |
| `--net restricted --allow dev` | + GitHub, npm, PyPI, crates.io, Go, Debian | Restricted, but installs work |
| `--net restricted --allow my.txt` | + your regexes (`^api\.corp\.com$`) | Project-specific APIs |
| `--net none` | Nothing | Offline builds/tests with `--shell` |

Restricted mode puts the sandbox on an `--internal` Podman network with no route out; the only
exit is the proxy container, which returns 403 for anything not allowlisted. Watch blocks with
`podman logs -f claude-proxy-<id>`; clean up with `claude-sandbox --stop-proxies`.

## 5. Authentication

| Mode | How | Notes |
|---|---|---|
| `--auth login` (default) | Subscription (Pro/Max/Team/Enterprise). Run once, open the URL, paste the code back | Saved in `claude-config` volume |
| `--auth token` | `claude setup-token`, then `printf '%s' TOKEN \| podman secret create claude_oauth_token -` | 1-year subscription token; model requests only |
| `--auth apikey` | `printf '%s' sk-ant-... \| podman secret create anthropic_api_key -` | Console pay-as-you-go |

Secrets are injected as env vars via `podman secret` and don't appear in `podman inspect`.
An API key takes precedence over a subscription login; check with `/status`.

## 6. Resume development

Containers are disposable (`--rm`); everything you need to pick up where you left off lives
outside them:

| What | Where | Survives |
|---|---|---|
| Source code, `.venv`, `node_modules`, `CLAUDE.md`, `.claude/` | your project dir on the host | everything |
| Login, settings, **session transcripts** (`~/.claude/projects/<path>/`) | `claude-config` volume | `--rm`, image rebuilds |
| `npm -g`, `pipx`, `go install`, `cargo install`, bash history | `claude-tools` volume | `--rm`, image rebuilds |
| npm/pip download caches | `claude-cache` volume | `--rm`, image rebuilds |
| Claude Code binary, apt packages | image | rebuild to update |

```bash
cd ~/code/my-app
claude-sandbox --continue          # latest conversation for THIS project
claude-sandbox --resume            # pick an older session for this project
claude-sandbox --resume my-feature # by name (start one with: claude-sandbox -- --name my-feature)
```

Because sessions are keyed by the project path, always start from the same directory. If you
move a project, its old sessions stay under the old path (`--mount-at OLD_PATH` reaches them).

Keep long sessions alive across terminal or SSH disconnects by running the launcher inside
`tmux` on the host: `tmux new -As my-app 'claude-sandbox --continue'`.

Move to a new machine (or back up):
```bash
for v in claude-config claude-tools; do podman volume export $v -o $v.tar; done   # old machine
for v in claude-config claude-tools; do podman volume create $v; podman volume import $v $v.tar; done  # new
```
`claude-config.tar` contains your credentials; store it like a password. Keep the project at the
same path on the new machine so `--continue` finds its sessions.

## macOS native sandbox

`macos/claude-mac-sandbox.sh` runs Claude Code under `sandbox-exec` (Seatbelt). Claude, `swift`,
`xcodebuild`, git and every other process it starts run natively with your normal toolchain and
Xcode, but:

| | Policy |
|---|---|
| Writes | only the project, Claude's config (`~/.claude`, `~/.claude.json`), `~/Library/Developer` (DerivedData, simulators), `~/Library/Caches`, SwiftPM state, temp. Not `~/.zshrc`, LaunchAgents, `/usr/local`, other projects, or the Claude binary |
| Git | `.git/config` and `.git/hooks` read-only (they run code later, outside the sandbox); `--allow-git-config` to lift |
| Reads | `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`, `~/.kube`, `~/.docker`, `~/.netrc`, `~/.npmrc` … denied; add more with `--hide` |
| Agent / env | ssh-agent socket blocked; your shell environment (tokens etc.) is not passed in |
| Keychain | usable by default (Claude's login lives there); `--no-keychain` blocks it |
| Network | `--net full` (default), `restricted` (Seatbelt blocks direct connections; a local tinyproxy allows Claude's hosts + `--allow` lists), `none` |

```bash
xcode-select --install || true                 # or install Xcode
curl -fsSL https://claude.ai/install.sh | bash # Claude Code, native installer
brew install tinyproxy                         # only for --net restricted
macos/check-macos.sh
ln -sf "$PWD/macos/claude-mac-sandbox.sh" ~/.local/bin/claude-mac-sandbox

cd ~/code/MyMacApp
claude-mac-sandbox                     # sign in once (Keychain), then work
claude-mac-sandbox --continue          # resume: sessions are keyed by the real project path
claude-mac-sandbox --net restricted --allow dev   # SwiftPM/GitHub allowed, everything else blocked
claude-mac-sandbox --net none --shell  # offline: swift build / swift test / xcodebuild test
```

Token or API key instead of the login: store it in the Keychain once
(`security add-generic-password -U -a "$USER" -s claude-sandbox-oauth-token -w`, or
`-s claude-sandbox-anthropic-api-key`) and pass `--auth token` / `--auth apikey`; combine with
`--no-keychain` for the tightest setup.

SwiftPM and Xcode sandbox `Package.swift` evaluation themselves, and macOS refuses nested
sandboxes, so the launcher puts small `swift`/`xcodebuild` shims first on `PATH` that disable
only that inner sandbox (the outer one still applies). For the same reason, don't enable Claude
Code's built-in `/sandbox` inside this launcher; use one or the other. The built-in sandbox is the
lighter option: it confines only Bash commands, while Claude's own file tools follow its permission
rules.

`examples/HelloMac` (library, CLI, SwiftUI view, XCTest) and `examples/WithDeps` (SwiftPM
dependency) are the sample projects the CI builds inside the sandbox.

## CI verification

`.github/workflows/verify-sandbox.yml` runs on every push/PR and weekly. The macOS jobs (macOS 15
and 14 runners) run `tests/macos/run-tests.sh`: confinement of writes and reads, Keychain and
ssh-agent, sign-in wiring, all network modes, `swift build`/`swift test`/`xcodebuild test` of the
sample project, SwiftPM fetching through the proxy, and per-project sessions. The Linux jobs (x86_64
and arm64 runners):
lint → build both images → `tests/run-tests.sh`, which checks prerequisites, image contents,
mount ownership and two-way visibility, per-project session isolation, persistence across runs,
image rebuilds and volume backup/restore, hardening, all three network modes (including proxy-bypass
attempts and real git/pip/npm through the allowlist), port publishing, and auth wiring.

To also exercise **real Claude Code sessions** end to end (restricted network, editing the
mounted project, `--resume`/`--continue` across containers and isolation between projects), add either or both repository secrets:
`ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`. Without them those tests are skipped.
The interactive browser `/login` flow can't be automated in CI; `CLAUDE_CODE_OAUTH_TOKEN`
covers the subscription path.

Run the suite locally the same way: `tests/run-tests.sh`.
