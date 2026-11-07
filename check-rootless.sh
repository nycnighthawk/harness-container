#!/usr/bin/env bash
# Verify this machine is ready to run claude-sandbox with rootless Podman.
# Prints PASS/WARN/FAIL with the fix for anything missing. Run as your normal user.
set -uo pipefail

fail=0
pass() { printf '  \e[32mPASS\e[0m %s\n' "$*"; }
warn() { printf '  \e[33mWARN\e[0m %s\n' "$*"; }
bad()  { printf '  \e[31mFAIL\e[0m %s\n' "$*"; fail=1; }
fix()  { printf '       fix: %s\n' "$*"; }

echo "Rootless Podman checks for user: $(id -un) (uid $(id -u))"

[[ $(id -u) -ne 0 ]] && pass "not running as root" || { bad "running as root"; fix "run as your normal user, without sudo"; }

if ! command -v podman >/dev/null; then
  bad "podman not installed"
  fix "Fedora/RHEL: sudo dnf install podman | Debian/Ubuntu: sudo apt install podman uidmap passt netavark aardvark-dns"
  exit 1
fi

ver="$(podman version --format '{{.Client.Version}}' 2>/dev/null)"
if printf '%s\n4.3.0\n' "$ver" | sort -V -C 2>/dev/null && [[ "$ver" != "4.3.0" ]]; then
  bad "podman $ver is too old (need >= 4.3 for --userns=keep-id:uid=,gid=)"
  fix "upgrade podman (Ubuntu 24.04+, Debian 12+, Fedora 38+ ship new enough versions)"
else
  pass "podman $ver"
fi

for f in /etc/subuid /etc/subgid; do
  if grep -qE "^($(id -un)|$(id -u)):" "$f" 2>/dev/null; then
    pass "$f has a range for $(id -un): $(grep -E "^($(id -un)|$(id -u)):" "$f" | head -1)"
  else
    bad "no subordinate ID range in $f"
    fix "sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un) && podman system migrate"
  fi
done

command -v newuidmap >/dev/null && pass "newuidmap/newgidmap present" \
  || { bad "newuidmap missing"; fix "install the 'uidmap' (Debian/Ubuntu) or 'shadow-utils' (Fedora) package"; }

rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)"
[[ "$rootless" == "true" ]] && pass "podman reports rootless mode" \
  || { bad "podman is not rootless (or 'podman info' failed)"; fix "podman system migrate; then re-run. Check 'podman info' for errors"; }

backend="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null)"
[[ "$backend" == "netavark" ]] && pass "network backend: netavark (needed for --net restricted DNS)" \
  || { warn "network backend: ${backend:-unknown} (restricted mode needs netavark + aardvark-dns)"; fix "install netavark aardvark-dns, then: podman system reset (DELETES all containers/images)"; }

cg="$(podman info --format '{{.Host.CgroupsVersion}}' 2>/dev/null)"
ctl="$(podman info --format '{{.Host.CgroupControllers}}' | tr -d '[]' 2>/dev/null)"
if [[ "$cg" == "v2" ]]; then
  pass "cgroups v2"
  for c in memory cpu pids; do
    [[ " $ctl " == *" $c "* ]] && pass "cgroup controller '$c' delegated" \
      || { warn "cgroup controller '$c' not delegated (limits will be skipped)"
           fix "sudo mkdir -p /etc/systemd/system/user@.service.d && printf '[Service]\\nDelegate=cpu cpuset io memory pids\\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf && sudo systemctl daemon-reload; then log out and back in"; }
  done
else
  warn "cgroups ${cg:-unknown}: resource limits (--memory/--cpus) unavailable rootless"
fi

if command -v getenforce >/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
  pass "SELinux enforcing (claude-sandbox uses :Z labels on mounts)"
fi

if podman run --rm --userns=keep-id:uid=1000,gid=1000 docker.io/library/busybox:latest \
     sh -c '[ "$(id -u)" = 1000 ]' >/dev/null 2>&1; then
  pass "test container ran with keep-id mapping"
else
  bad "test container failed"; fix "run: podman run --rm --userns=keep-id:uid=1000,gid=1000 docker.io/library/busybox id   and read the error"
fi

echo
((fail)) && { echo "Some checks failed. Fix them and re-run."; exit 1; } || echo "All required checks passed."
