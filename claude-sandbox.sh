#!/usr/bin/env bash
# shellcheck disable=SC2054  # commas are part of podman option values
# claude-sandbox: run Claude Code in a rootless Podman container with your
# project mounted read-write, and a selectable network policy.
#
#   claude-sandbox [options] [-- claude args...]
#
# Network (--net):
#   full        Unrestricted outbound network (default). Port publishing works.
#   restricted  No direct internet. All traffic goes through an allowlist proxy:
#               Claude's own hosts always, plus any --allow lists.
#   none        No network at all. Claude can't reach its API, so use with
#               --shell (offline builds/tests) only.
#
# Options:
#   --net MODE          full | restricted | none
#   --allow NAME|FILE   add an allowlist (allowlist/NAME.txt or a path); repeatable
#   --auth MODE         login (default) | token | apikey   (see README)
#   -p, --port PORT     publish PORT (or HOST:CONTAINER) on 127.0.0.1 (full mode)
#   --project DIR       project to mount at /workspace (default: $PWD)
#   --ro                mount the project read-only
#   --gitconfig         mount ~/.gitconfig read-only (author name/email)
#   --yolo              pass --dangerously-skip-permissions to claude
#   --shell             start bash instead of claude
#   --memory SIZE       memory limit (default 8g)   --cpus N (default 4)
#   --stop-proxies      remove all running allowlist proxies and exit
#   -h, --help
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
IMAGE="${IMAGE:-localhost/claude-sandbox:latest}"
PROXY_IMAGE="${PROXY_IMAGE:-localhost/claude-sandbox-proxy:latest}"
CONFIG_VOLUME="${CONFIG_VOLUME:-claude-config}"
CACHE_VOLUME="${CACHE_VOLUME:-claude-cache}"
NET_INTERNAL="claude-internal"
NET_EGRESS="claude-egress"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-sandbox"

net=full auth=login project="$PWD" ro=0 gitconfig=0 yolo=0 shell=0
memory=8g cpus=4
allows=() ports=() passthru=()

die() { echo "claude-sandbox: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0; }

while (($#)); do
  case "$1" in
    --net)       net="${2:?}"; shift 2 ;;
    --allow)     allows+=("${2:?}"); shift 2 ;;
    --auth)      auth="${2:?}"; shift 2 ;;
    -p|--port)   ports+=("${2:?}"); shift 2 ;;
    --project)   project="$(cd "${2:?}" && pwd)"; shift 2 ;;
    --ro)        ro=1; shift ;;
    --gitconfig) gitconfig=1; shift ;;
    --yolo)      yolo=1; shift ;;
    --shell)     shell=1; shift ;;
    --memory)    memory="${2:?}"; shift 2 ;;
    --cpus)      cpus="${2:?}"; shift 2 ;;
    --stop-proxies)
      podman ps -a --filter label=claude-sandbox.proxy -q | xargs -r podman rm -f
      exit 0 ;;
    -h|--help)   usage ;;
    --)          shift; passthru+=("$@"); break ;;
    *)           passthru+=("$1"); shift ;;
  esac
done

[[ "$(podman info --format '{{.Host.Security.Rootless}}')" == "true" ]] \
  || die "podman is not running rootless. Run as your normal user (no sudo)."

# ---------------------------------------------------------------- base args
name="claude-$(basename "$project" | tr -c 'a-zA-Z0-9_.\n' '-')-$$"
tty=(-i); [[ -t 0 && -t 1 ]] && tty=(-it)   # no -t in CI / pipes
args=(
  run --rm "${tty[@]}" --name "$name" --hostname claude-sandbox
  --label claude-sandbox=1
  # Host UID <-> container 'claude' (1000): project files stay owned by you.
  --userns=keep-id:uid=1000,gid=1000
  --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=2048
  --init
  -w /workspace
  -e TERM="${TERM:-xterm-256color}"
  -v "$CONFIG_VOLUME":/home/claude/.claude:U
  -v "$CACHE_VOLUME":/home/claude/.cache:U
)

# Resource limits only if the cgroup controllers are delegated to this user.
controllers="$(podman info --format '{{.Host.CgroupControllers}}' | tr -d '[]' 2>/dev/null || true)"
[[ " $controllers " == *" memory "* ]] && args+=(--memory="$memory")
[[ " $controllers " == *" cpu "* ]]    && args+=(--cpus="$cpus")

# Project mount (:Z = private SELinux label; harmless on non-SELinux hosts).
if ((ro)); then args+=(-v "$project":/workspace:ro,Z); else args+=(-v "$project":/workspace:Z); fi
((gitconfig)) && [[ -f "$HOME/.gitconfig" ]] && args+=(-v "$HOME/.gitconfig":/home/claude/.gitconfig:ro,Z)

# -------------------------------------------------------------------- auth
secret_ok() { podman secret inspect "$1" >/dev/null 2>&1; }
case "$auth" in
  login)  ;;  # subscription via /login; saved in the config volume
  token)  secret_ok claude_oauth_token || die "create secret claude_oauth_token first"
          args+=(--secret claude_oauth_token,type=mount,uid=1000,gid=1000,mode=0400) ;;
  apikey) secret_ok anthropic_api_key || die "create secret anthropic_api_key first"
          args+=(--secret anthropic_api_key,type=mount,uid=1000,gid=1000,mode=0400) ;;
  *)      die "unknown --auth '$auth' (login|token|apikey)" ;;
esac

# ----------------------------------------------------------------- network
ensure_net() { # name [--internal]
  podman network exists "$1" || podman network create "${@:2}" "$1" >/dev/null
}

start_proxy() {
  mkdir -p "$STATE_DIR"
  local files=("$HERE/allowlist/claude.txt") a f
  for a in "${allows[@]}"; do
    if [[ -f "$a" ]]; then f="$a"; else f="$HERE/allowlist/$a.txt"; fi
    [[ -f "$f" ]] || die "allowlist not found: $a"
    files+=("$f")
  done
  local list hash
  list="$(grep -hvE '^[[:space:]]*(#|$)' "${files[@]}" | sort -u)"
  hash="$(printf '%s' "$list" | sha256sum | cut -c1-10)"
  PROXY_NAME="claude-proxy-$hash"
  printf '%s\n' "$list" > "$STATE_DIR/allowlist-$hash"

  podman image exists "$PROXY_IMAGE" || \
    podman build -q -t "$PROXY_IMAGE" "$HERE/proxy" >/dev/null
  ensure_net "$NET_INTERNAL" --internal
  ensure_net "$NET_EGRESS"
  if [[ "$(podman inspect -f '{{.State.Running}}' "$PROXY_NAME" 2>/dev/null)" != "true" ]]; then
    podman rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
    podman run -d --name "$PROXY_NAME" --label claude-sandbox.proxy=1 \
      --network "$NET_INTERNAL" --network "$NET_EGRESS" \
      --cap-drop=ALL --security-opt=no-new-privileges --read-only --tmpfs /tmp \
      -v "$STATE_DIR/allowlist-$hash":/etc/tinyproxy/allowlist:ro,Z \
      "$PROXY_IMAGE" >/dev/null
  fi
  echo "claude-sandbox: restricted network via $PROXY_NAME (logs: podman logs -f $PROXY_NAME)" >&2
}

case "$net" in
  full)
    # podman's default rootless networking (pasta or slirp4netns)
    for p in "${ports[@]}"; do
      if [[ "$p" == *:* ]]; then args+=(-p "127.0.0.1:$p"); else args+=(-p "127.0.0.1:$p:$p"); fi
    done ;;
  restricted)
    ((${#ports[@]})) && die "--port is not supported with --net restricted (internal network)"
    start_proxy
    proxy="http://$PROXY_NAME:3128"
    args+=(--network "$NET_INTERNAL"
           -e HTTPS_PROXY="$proxy" -e https_proxy="$proxy"
           -e HTTP_PROXY="$proxy"  -e http_proxy="$proxy"
           -e NO_PROXY=localhost,127.0.0.1 -e no_proxy=localhost,127.0.0.1
           -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1) ;;
  none)
    ((shell)) || echo "claude-sandbox: warning: --net none blocks the Claude API; claude will not work. Use --shell." >&2
    args+=(--network none) ;;
  *) die "unknown --net '$net' (full|restricted|none)" ;;
esac

# --------------------------------------------------------------------- run
if ((shell)); then
  args+=("$IMAGE" --shell "${passthru[@]}")
else
  ((yolo)) && passthru=(--dangerously-skip-permissions "${passthru[@]}")
  args+=("$IMAGE" "${passthru[@]}")
fi

exec podman "${args[@]}"
