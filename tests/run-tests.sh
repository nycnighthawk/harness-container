#!/usr/bin/env bash
# End-to-end verification of the Claude Code Podman sandbox.
# Runs locally or in GitHub Actions. Requires rootless podman and built images:
#   podman build -t claude-sandbox . && podman build -t claude-sandbox-proxy proxy/
#
# Optional live tests (skipped when unset):
#   ANTHROPIC_API_KEY        -> real Claude call via --auth apikey
#   CLAUDE_CODE_OAUTH_TOKEN  -> real Claude call via --auth token (subscription)
set -uo pipefail
# shellcheck disable=SC2016  # single-quoted $VARS are expanded inside the container

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$ROOT/claude-sandbox.sh"
RUN_ID="t$$"
export CONFIG_VOLUME="claude-config-$RUN_ID" CACHE_VOLUME="claude-cache-$RUN_ID"
PROJ="$(mktemp -d)"; chmod 755 "$PROJ"
pass=0 fail=0 skip=0 failed=()

gh_annot() { [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::$1 title=$2::$3"; }
ok()   { ((pass++)); printf '\e[32m  ok  \e[0m %s\n' "$1"; }
nok()  { ((fail++)); failed+=("$1"); printf '\e[31m FAIL \e[0m %s\n' "$1"
         [[ -n "${2:-}" ]] && printf '       %s\n' "${2//$'\n'/$'\n'       }"
         gh_annot error "$1" "$(printf '%s' "${2:-}" | tail -c 900 | tr '\n' ' ')"; }
skp()  { ((skip++)); printf '\e[33m skip \e[0m %s\n' "$1"; gh_annot notice "skipped: $1" "${2:-}"; }
section() { printf '\n\e[1m== %s\e[0m\n' "$1"; [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::group::$1"; :; }
endsec()  { [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::endgroup::"; :; }

# sb [launcher opts...] -- bash command    (runs bash -c inside the sandbox)
sb() {
  local opts=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do opts+=("$1"); shift; done
  shift
  "$SB" --project "$PROJ" "${opts[@]}" --shell -c "$*" </dev/null 2>&1
}
# expect NAME CMD...   -> pass if CMD exits 0
expect()    { local n="$1"; shift; local out; if out="$("$@")"; then ok "$n"; else nok "$n" "$out"; fi; }
expect_no() { local n="$1"; shift; local out; if out="$("$@")"; then nok "$n" "expected failure, got success: $out"; else ok "$n"; fi; }

cleanup() {
  podman volume rm -f "$CONFIG_VOLUME" "$CACHE_VOLUME" >/dev/null 2>&1
  podman secret rm anthropic_api_key claude_oauth_token >/dev/null 2>&1
  "$SB" --stop-proxies >/dev/null 2>&1
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$PROJ"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
section "Host: rootless podman prerequisites"
expect "check-rootless.sh passes" "$ROOT/check-rootless.sh"
expect "launcher --help works" "$SB" --help
endsec

section "Image contents"
expect "claude CLI runs"              sb -- 'claude --version'
expect "node + npm present"           sb -- 'node --version && npm --version'
expect "python3 + venv works"         sb -- 'python3 -m venv /tmp/v && /tmp/v/bin/pip --version'
expect "git, rg, make, gcc present"   sb -- 'git --version && rg --version && make --version && gcc --version'
expect "runs as non-root 'claude'"    sb -- '[ "$(id -u)" = 1000 ] && [ "$(id -un)" = claude ]'
expect "auto-updater disabled"        sb -- '[ "$DISABLE_AUTOUPDATER" = 1 ]'
expect "CLAUDE_CONFIG_DIR in volume"  sb -- '[ "$CLAUDE_CONFIG_DIR" = /home/claude/.claude ] && [ -w "$CLAUDE_CONFIG_DIR" ]'
endsec

section "Project mount (rootless keep-id)"
echo "from-host" > "$PROJ/host.txt"
expect "host file readable in /workspace"  sb -- 'grep -q from-host /workspace/host.txt'
expect "container can write to project"    sb -- 'echo from-sandbox > /workspace/made-inside.txt && mkdir -p /workspace/sub/dir'
if [[ -f "$PROJ/made-inside.txt" && "$(stat -c %u "$PROJ/made-inside.txt")" == "$(id -u)" ]]; then
  ok "files created inside are owned by host user $(id -un) (uid $(id -u))"
else
  nok "files created inside are owned by host user" "$(ls -ln "$PROJ")"
fi
expect    "host can edit/delete files created inside" rm -rf "$PROJ/made-inside.txt" "$PROJ/sub"
expect_no "--ro blocks writes"                         sb --ro -- 'touch /workspace/nope'
endsec

section "Persistence across runs (named volumes)"
expect "write to config volume"        sb -- 'echo persisted > ~/.claude/probe'
expect "config volume survives --rm"   sb -- 'grep -q persisted ~/.claude/probe'
expect "cache volume writable"         sb -- 'echo x > ~/.cache/probe && grep -q x ~/.cache/probe'
endsec

section "Hardening"
expect    "no effective capabilities"   sb -- 'grep -q "^CapEff:[[:space:]]*0000000000000000" /proc/self/status'
expect    "no_new_privs set"            sb -- 'grep -q "^NoNewPrivs:[[:space:]]*1" /proc/self/status'
expect_no "cannot become root"          sb -- 'su -c id root </dev/null'
expect    "host ~/.ssh not visible"     sb -- '[ ! -e ~/.ssh ]'
expect    "sudo not available"          sb -- '! command -v sudo'
endsec

section "Network: --net none"
expect    "only loopback interface"     sb --net none -- '[ "$(grep -c : /proc/net/dev)" = 1 ] && grep -q "lo:" /proc/net/dev'
expect_no "internet unreachable"        sb --net none -- 'curl -sS --max-time 8 https://example.com -o /dev/null'
endsec

section "Network: --net full"
expect "internet reachable"             sb --net full -- 'curl -sSf --max-time 20 https://example.com -o /dev/null'
expect "Anthropic API reachable"        sb --net full -- 'c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 https://api.anthropic.com/v1/models); [ "$c" != 000 ]'
# Port publishing: dev server inside, curl from host.
"$SB" --project "$PROJ" --net full -p 18080:8000 --shell -c 'cd /workspace && exec python3 -m http.server 8000 --bind 0.0.0.0' </dev/null >/tmp/srv.log 2>&1 &
SERVER_PID=$!
got=""; for _ in $(seq 1 30); do got="$(curl -s --max-time 2 http://127.0.0.1:18080/host.txt)" && [[ "$got" == from-host ]] && break; sleep 1; done
if [[ "$got" == from-host ]]; then ok "published port 127.0.0.1:18080 serves project files"; else nok "published port reachable from host" "$(cat /tmp/srv.log)"; fi
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
expect_no "--port rejected with --net restricted" "$SB" --project "$PROJ" --net restricted -p 3000 --shell -c true
endsec

code() { echo 'c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 '"$1"'); echo "$c"; [ "$c" != 000 ]'; }

section "Network: --net restricted (Claude hosts only)"
expect    "proxy env set"                       sb --net restricted -- '[ -n "$HTTPS_PROXY" ]'
expect    "api.anthropic.com allowed"           sb --net restricted -- "$(code https://api.anthropic.com/v1/models)"
expect    "platform.claude.com allowed (login)" sb --net restricted -- "$(code https://platform.claude.com/)"
expect_no "example.com blocked"                 sb --net restricted -- "$(code https://example.com/)"
expect_no "github.com blocked without --allow dev" sb --net restricted -- "$(code https://github.com/)"
expect_no "look-alike host blocked"             sb --net restricted -- "$(code https://api.anthropic.com.evil.example/)"
expect_no "bypassing proxy (direct IP) fails"   sb --net restricted -- 'curl -sS --noproxy "*" --max-time 8 https://1.1.1.1 -o /dev/null'
expect_no "bypassing proxy (direct DNS) fails"  sb --net restricted -- 'curl -sS --noproxy "*" --max-time 8 https://api.anthropic.com -o /dev/null'
proxy="$(podman ps --filter label=claude-sandbox.proxy -q | head -1)"
if [[ -n "$proxy" ]] && podman logs "$proxy" 2>&1 | grep -q 'refused on filtered domain "example.com"'; then
  ok "proxy log records the blocked host"
else
  nok "proxy log records the blocked host" "$( [[ -n "$proxy" ]] && podman logs "$proxy" 2>&1 | tail -20)"
fi
endsec

section "Network: --net restricted --allow dev"
expect    "github.com allowed"           sb --net restricted --allow dev -- "$(code https://github.com/)"
expect    "git clone over HTTPS"         sb --net restricted --allow dev -- 'git clone -q --depth 1 https://github.com/octocat/Hello-World /tmp/hw && test -f /tmp/hw/README'
expect    "pip install (PyPI)"           sb --net restricted --allow dev -- 'python3 -m venv /tmp/v && /tmp/v/bin/pip install -q six && /tmp/v/bin/python -c "import six"'
expect    "npm install (npm registry)"   sb --net restricted --allow dev -- 'cd /tmp && npm init -y >/dev/null && npm install --silent left-pad && test -d node_modules/left-pad'
expect_no "example.com still blocked"    sb --net restricted --allow dev -- "$(code https://example.com/)"
printf '^example\\.com$\n' > "$PROJ/../custom-allow-$RUN_ID.txt"
expect    "custom --allow FILE works"    sb --net restricted --allow "$PROJ/../custom-allow-$RUN_ID.txt" -- "$(code https://example.com/)"
rm -f "$PROJ/../custom-allow-$RUN_ID.txt"
n_before="$(podman ps --filter label=claude-sandbox.proxy -q | wc -l)"
expect    "--stop-proxies removes proxies" "$SB" --stop-proxies
n_after="$(podman ps -a --filter label=claude-sandbox.proxy -q | wc -l)"
[[ "$n_before" -ge 1 && "$n_after" -eq 0 ]] && ok "proxies: $n_before running -> 0 after stop" || nok "proxy cleanup" "before=$n_before after=$n_after"
endsec

section "Auth wiring (dummy credentials, no network)"
printf '%s' 'sk-ant-api03-DUMMY' | podman secret create anthropic_api_key - >/dev/null
printf '%s' 'sk-ant-oat01-DUMMY' | podman secret create claude_oauth_token - >/dev/null
expect    "--auth apikey injects ANTHROPIC_API_KEY"      sb --net none --auth apikey -- '[ "$ANTHROPIC_API_KEY" = sk-ant-api03-DUMMY ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]'
expect    "--auth token injects CLAUDE_CODE_OAUTH_TOKEN" sb --net none --auth token  -- '[ "$CLAUDE_CODE_OAUTH_TOKEN" = sk-ant-oat01-DUMMY ] && [ -z "${ANTHROPIC_API_KEY:-}" ]'
expect    "--auth login injects no credential"           sb --net none --auth login  -- '[ -z "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]'
# The secret value must not leak into container metadata.
"$SB" --project "$PROJ" --net none --auth apikey --shell -c 'sleep 20' </dev/null >/dev/null 2>&1 &
bg=$!; sleep 4
cid="$(podman ps --filter label=claude-sandbox=1 -q | head -1)"
if [[ -n "$cid" ]] && ! podman inspect "$cid" | grep -q 'sk-ant-api03-DUMMY'; then ok "secret value absent from podman inspect"
else nok "secret value absent from podman inspect" "cid=$cid"; fi
[[ -n "$cid" ]] && podman rm -f "$cid" >/dev/null 2>&1; wait "$bg" 2>/dev/null
podman secret rm anthropic_api_key claude_oauth_token >/dev/null
expect_no "--auth apikey fails cleanly without secret" "$SB" --project "$PROJ" --auth apikey --shell -c true
endsec

live() { # live NAME AUTH SECRET_NAME VALUE
  local name="$1" auth="$2" sname="$3" val="$4" out
  printf '%s' "$val" | podman secret create "$sname" - >/dev/null
  out="$("$SB" --project "$PROJ" --net restricted --auth "$auth" -- -p 'Reply with exactly the word SANDBOX_OK and nothing else.' </dev/null 2>&1)"
  if grep -q SANDBOX_OK <<<"$out"; then ok "$name: claude -p answers through restricted network"; else nok "$name: claude -p answers" "$out"; fi
  rm -f "$PROJ/hello.txt"
  out="$("$SB" --project "$PROJ" --net restricted --auth "$auth" --yolo -- -p 'Use your tools to create a file named hello.txt in the current directory containing exactly: hi from sandbox' </dev/null 2>&1)"
  if grep -q 'hi from sandbox' "$PROJ/hello.txt" 2>/dev/null && [[ "$(stat -c %u "$PROJ/hello.txt")" == "$(id -u)" ]]; then
    ok "$name: Claude edited the mounted project (file owned by host user)"
  else nok "$name: Claude edited the mounted project" "$out"; fi
  podman secret rm "$sname" >/dev/null
}

section "Live Claude Code (optional secrets)"
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then live "API key" apikey anthropic_api_key "$ANTHROPIC_API_KEY"
else skp "live API-key test" "set repo secret ANTHROPIC_API_KEY to enable"; fi
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then live "Subscription token" token claude_oauth_token "$CLAUDE_CODE_OAUTH_TOKEN"
else skp "live subscription-token test" "set repo secret CLAUDE_CODE_OAUTH_TOKEN (from 'claude setup-token') to enable"; fi
endsec

# ---------------------------------------------------------------------------
printf '\n\e[1mResult: %d passed, %d failed, %d skipped\e[0m\n' "$pass" "$fail" "$skip"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { echo "### Sandbox verification ($(uname -m))"; echo
    echo "| passed | failed | skipped |"; echo "|---|---|---|"; echo "| $pass | $fail | $skip |"
    ((fail)) && { echo; echo "**Failed:**"; printf -- '- %s\n' "${failed[@]}"; }
  } >> "$GITHUB_STEP_SUMMARY"
fi
((fail == 0))
