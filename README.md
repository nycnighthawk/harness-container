# harness-container

Run [Claude Code](https://code.claude.com/docs) in a **rootless Podman** sandbox with your
project mounted for full development, and a network policy you choose per run.

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

Files created in the sandbox are owned by **you** on the host (`--userns=keep-id`). Login/settings
persist in the `claude-config` volume, npm/pip caches in `claude-cache`. The container has no
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

## CI verification

`.github/workflows/verify-sandbox.yml` runs on every push/PR (x86_64 and arm64 runners) and weekly:
lint → build both images → `tests/run-tests.sh`, which checks prerequisites, image contents,
mount ownership, volume persistence, hardening, all three network modes (including proxy-bypass
attempts and real git/pip/npm through the allowlist), port publishing, and auth wiring.

To also exercise **real Claude Code sessions** end to end (restricted network, editing the
mounted project), add either or both repository secrets:
`ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`. Without them those tests are skipped.
The interactive browser `/login` flow can't be automated in CI; `CLAUDE_CODE_OAUTH_TOKEN`
covers the subscription path.

Run the suite locally the same way: `tests/run-tests.sh`.
