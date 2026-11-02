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
export CONFIG_VOLUME="claude-config-$RUN_ID" CACHE_VOLUME="claude-cache-$RUN_ID" TOOLS_VOLUME="claude-tools-$RUN_ID"
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
  podman volume rm -f "$CONFIG_VOLUME" "$CACHE_VOLUME" "$TOOLS_VOLUME" >/dev/null 2>&1
  rm -rf "${PROJ2:-/nonexistent}"
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

section "Project mount: writes inside are visible to the host user"
U="$(id -u)" G="$(id -g)"
# eq NAME ACTUAL EXPECTED
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected: $3"$'\n'"actual:   $2"; fi; }
owner() { stat -c '%u:%g' "$1" 2>/dev/null; }

# 1. host -> container
echo "from-host" > "$PROJ/host.txt"
eq "host-created file readable inside" "$(sb -- 'cat $SANDBOX_PROJECT_DIR/host.txt')" "from-host"

# 2. container creates a file -> host sees exact content, owned by host user
sb -- 'printf "line1\nline2\n" > $SANDBOX_PROJECT_DIR/new.txt' >/dev/null
eq "new file content visible on host"          "$(cat "$PROJ/new.txt" 2>&1)" $'line1\nline2'
eq "new file owned by host user ($U:$G)"       "$(owner "$PROJ/new.txt")" "$U:$G"
eq "new file has normal perms (644)"           "$(stat -c %a "$PROJ/new.txt")" "644"

# 3. container edits a host file in place (sed -i rewrites via temp file + rename)
printf 'version=1\nname=demo\n' > "$PROJ/config.ini"; chmod 640 "$PROJ/config.ini"
sb -- 'sed -i "s/version=1/version=2/" $SANDBOX_PROJECT_DIR/config.ini && echo "edited=yes" >> $SANDBOX_PROJECT_DIR/config.ini' >/dev/null
eq "in-place edit visible on host"             "$(cat "$PROJ/config.ini")" $'version=2\nname=demo\nedited=yes'
eq "edited file still owned by host user"      "$(owner "$PROJ/config.ini")" "$U:$G"
eq "edited file keeps its mode (640)"          "$(stat -c %a "$PROJ/config.ini")" "640"

# 4. host edits after the container wrote -> container sees host's change
echo "host-update" >> "$PROJ/new.txt"
eq "host's later edit visible inside"          "$(sb -- 'tail -1 $SANDBOX_PROJECT_DIR/new.txt')" "host-update"

# 5. directories, rename, delete, exec bit
sb -- 'mkdir -p $SANDBOX_PROJECT_DIR/src/pkg && echo "print(1)" > $SANDBOX_PROJECT_DIR/src/pkg/main.py && mv $SANDBOX_PROJECT_DIR/new.txt $SANDBOX_PROJECT_DIR/renamed.txt && rm $SANDBOX_PROJECT_DIR/host.txt && printf "#!/bin/sh\necho ran\n" > $SANDBOX_PROJECT_DIR/run.sh && chmod +x $SANDBOX_PROJECT_DIR/run.sh' >/dev/null
eq "nested dirs owned by host user"            "$(owner "$PROJ/src/pkg")" "$U:$G"
expect "host can write into dirs made inside"  touch "$PROJ/src/pkg/host-added.py"
eq "rename visible on host"                    "$( [[ -f "$PROJ/renamed.txt" && ! -e "$PROJ/new.txt" ]] && echo yes)" "yes"
eq "delete visible on host"                    "$( [[ ! -e "$PROJ/host.txt" ]] && echo gone)" "gone"
eq "exec bit set inside works on host"         "$("$PROJ/run.sh" 2>&1)" "ran"

# 6. byte-exact transfer both directions (5 MiB random)
head -c 5242880 /dev/urandom > "$PROJ/blob-host.bin"
eq "host binary identical inside (sha256)"     "$(sb -- 'sha256sum < $SANDBOX_PROJECT_DIR/blob-host.bin' | cut -d' ' -f1)" "$(sha256sum < "$PROJ/blob-host.bin" | cut -d' ' -f1)"
inner="$(sb -- 'head -c 5242880 /dev/urandom > $SANDBOX_PROJECT_DIR/blob-ctr.bin && sha256sum < $SANDBOX_PROJECT_DIR/blob-ctr.bin' | cut -d' ' -f1)"
eq "container binary identical on host (sha256)" "$(sha256sum < "$PROJ/blob-ctr.bin" | cut -d' ' -f1)" "$inner"

# 7. a host file only the user can read (600) is accessible inside (keep-id mapping)
echo "private" > "$PROJ/secret.txt"; chmod 600 "$PROJ/secret.txt"
eq "mode-600 host file readable+writable inside" "$(sb -- 'echo more >> $SANDBOX_PROJECT_DIR/secret.txt && cat $SANDBOX_PROJECT_DIR/secret.txt')" $'private\nmore'

# 8. git: commit inside, host git sees it with no 'dubious ownership' error
sb -- 'cd $SANDBOX_PROJECT_DIR && git init -q && git add -A && git -c user.name=sandbox -c user.email=s@example.com commit -qm "commit from sandbox"' >/dev/null
eq "host git log shows sandbox commit"         "$(git -C "$PROJ" log -1 --format=%s 2>&1)" "commit from sandbox"
eq "host git status clean (no ownership issues)" "$(git -C "$PROJ" status --porcelain 2>&1 | grep -v host-added || true)" ""
eq ".git objects owned by host user"           "$(find "$PROJ/.git" ! -user "$U" | head -3)" ""

# 9. live: while the container keeps running, changes show up both ways
"$SB" --project "$PROJ" --net none --shell -c 'sleep 300' </dev/null >/dev/null 2>&1 &
live_bg=$!
cid=""; for _ in $(seq 1 30); do cid="$(podman ps --filter label=claude-sandbox=1 --filter status=running -q | head -1)"; [[ -n "$cid" ]] && break; sleep 1; done
if [[ -n "$cid" ]]; then
  echo "v1" > "$PROJ/live.txt"
  eq "live: host write seen by running container"   "$(podman exec "$cid" cat "$PROJ/live.txt")" "v1"
  echo "v2" > "$PROJ/live.txt"
  eq "live: host update seen without restart"       "$(podman exec "$cid" cat "$PROJ/live.txt")" "v2"
  podman exec "$cid" sh -c 'echo "from-running-container" > $SANDBOX_PROJECT_DIR/live-out.txt'
  eq "live: container write seen by host immediately" "$(cat "$PROJ/live-out.txt" 2>&1)" "from-running-container"
  eq "live: written as host user"                   "$(owner "$PROJ/live-out.txt")" "$U:$G"
  podman exec "$cid" sh -c 'for i in 1 2 3; do echo "tick $i" >> $SANDBOX_PROJECT_DIR/live-out.txt; done'
  eq "live: appends streamed to host"               "$(tail -1 "$PROJ/live-out.txt")" "tick 3"
  podman rm -f "$cid" >/dev/null 2>&1
else
  nok "live: running sandbox container started" "no running container found"
fi
wait "$live_bg" 2>/dev/null

# 10. host user can clean up everything the sandbox created
expect    "host user can delete all sandbox-created files" rm -rf "$PROJ/src" "$PROJ/.git" "$PROJ/renamed.txt" "$PROJ/run.sh" "$PROJ/blob-host.bin" "$PROJ/blob-ctr.bin" "$PROJ/secret.txt" "$PROJ/config.ini" "$PROJ/live.txt" "$PROJ/live-out.txt"
eq        "project dir empty after cleanup" "$(ls -A "$PROJ")" ""
expect_no "--ro blocks writes"                         sb --ro -- 'touch $SANDBOX_PROJECT_DIR/nope'
echo "from-host" > "$PROJ/host.txt"   # used by the port-publishing test
endsec

section "Persistence across runs (named volumes)"
expect "write to config volume"        sb -- 'echo persisted > ~/.claude/probe'
expect "config volume survives --rm"   sb -- 'grep -q persisted ~/.claude/probe'
expect "cache volume writable"         sb -- 'echo x > ~/.cache/probe && grep -q x ~/.cache/probe'
endsec

section "Resume: per-project sessions and persistent state"
PROJ2="$(mktemp -d)"; chmod 755 "$PROJ2"
eq "project mounted at its host path (cwd inside = $PROJ)" "$(sb -- pwd)" "$PROJ"
eq "SANDBOX_PROJECT_DIR matches host path"  "$(sb -- 'echo "$SANDBOX_PROJECT_DIR"')" "$PROJ"
eq "second project gets its own path"       "$("$SB" --project "$PROJ2" --shell -c pwd </dev/null 2>&1)" "$PROJ2"
eq "--mount-at overrides the mount path"    "$("$SB" --project "$PROJ2" --mount-at /workspace/demo --shell -c pwd </dev/null 2>&1)" "/workspace/demo"
expect_no "refuses to mount your whole \$HOME" "$SB" --project "$HOME" --shell -c true
expect_no "refuses system mount paths"         "$SB" --project "$PROJ2" --mount-at /etc/demo --shell -c true

# Claude keys sessions by cwd: ~/.claude/projects/<encoded cwd>/<session>.jsonl.
# Simulate a transcript in project 1 and check it is visible to project 1 only.
enc='d="$CLAUDE_CONFIG_DIR/projects/$(pwd | sed "s#[^a-zA-Z0-9]#-#g")"'
sb -- "$enc"' && mkdir -p "$d" && echo "{}" > "$d/sess-$RANDOM.jsonl"' >/dev/null
eq "session bucket for project 1 persists across runs" "$(sb -- "$enc"' && ls "$d" | wc -l')" "1"
eq "project 2 does not see project 1 sessions" "$("$SB" --project "$PROJ2" --shell -c "$enc"' && ls "$d" 2>/dev/null | wc -l' </dev/null 2>&1)" "0"
"$SB" --project "$PROJ2" --shell -c "$enc"' && mkdir -p "$d" && echo "{}" > "$d/sess-$RANDOM.jsonl"' </dev/null >/dev/null 2>&1
eq "two projects -> two separate session dirs" "$(sb -- 'ls "$CLAUDE_CONFIG_DIR/projects" | wc -l')" "2"
eq "project 1 still sees only its own session" "$(sb -- "$enc"' && ls "$d" | wc -l')" "1"

# User-installed tools and shell history persist (tools volume).
sb -- 'mkdir -p ~/.tools/bin && printf "#!/bin/sh\necho tool-ok\n" > ~/.tools/bin/hello-tool && chmod +x ~/.tools/bin/hello-tool && echo "make test # marker-42" >> "$HISTFILE"' >/dev/null
eq "tool installed in earlier run is on PATH"  "$(sb -- 'hello-tool')" "tool-ok"
eq "shell history persists (HISTFILE in tools volume)" "$(sb -- 'grep -c marker-42 "$HISTFILE"')" "1"
sb --net full -- 'npm install -g --silent semver@7 >/dev/null 2>&1' >/dev/null
eq "npm -g package persists across runs"       "$(sb -- 'semver 1.2.3')" "1.2.3"

# State survives an image rebuild/upgrade (new image, same volumes).
printf 'FROM localhost/claude-sandbox:latest\nRUN true\n' | podman build -q -t localhost/claude-sandbox:next -f - . >/dev/null 2>&1
eq "state survives image rebuild" "$(IMAGE=localhost/claude-sandbox:next "$SB" --project "$PROJ" --shell -c 'cat ~/.claude/probe; hello-tool' </dev/null 2>&1)" $'persisted\ntool-ok'
podman rmi -f localhost/claude-sandbox:next >/dev/null 2>&1

# Backup -> restore into a fresh volume (moving to a new machine).
podman volume export "$CONFIG_VOLUME" -o /tmp/claude-config-$RUN_ID.tar
podman volume create "restored-$RUN_ID" >/dev/null && podman volume import "restored-$RUN_ID" /tmp/claude-config-$RUN_ID.tar
eq "config volume export/import restores state" "$(CONFIG_VOLUME="restored-$RUN_ID" "$SB" --project "$PROJ" --shell -c 'cat ~/.claude/probe; '"$enc"' && ls "$d" | wc -l' </dev/null 2>&1)" $'persisted\n1'
podman volume rm -f "restored-$RUN_ID" >/dev/null; rm -f /tmp/claude-config-$RUN_ID.tar
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
"$SB" --project "$PROJ" --net full -p 18080:8000 --shell -c 'cd $SANDBOX_PROJECT_DIR && exec python3 -m http.server 8000 --bind 0.0.0.0' </dev/null >/tmp/srv.log 2>&1 &
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
plog="$( [[ -n "$proxy" ]] && podman logs "$proxy" 2>&1)"
if [[ "$plog" == *'refused on filtered domain "example.com"'* ]]; then
  ok "proxy log records the blocked host"
else
  nok "proxy log records the blocked host" "$(tail -20 <<<"$plog")"
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
insp="$( [[ -n "$cid" ]] && podman inspect "$cid")"
if [[ -n "$insp" && "$insp" != *sk-ant-api03-DUMMY* ]]; then ok "secret value absent from podman inspect"
else nok "secret value absent from podman inspect" "cid=$cid $(grep -n DUMMY <<<"$insp" | head -3)"; fi
expect "secret file readable only by sandbox user" sb --net none --auth apikey -- '[ "$(stat -c "%u %a" /run/secrets/anthropic_api_key)" = "1000 400" ]' 
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
  # Resume: same project continues the conversation; another project can't see it.
  local sid; sid="$(cat /proc/sys/kernel/random/uuid)"
  "$SB" --project "$PROJ" --net restricted --auth "$auth" -- -p --session-id "$sid" 'Remember this codeword: PINEAPPLE-42. Reply with just OK.' </dev/null >/dev/null 2>&1
  out="$("$SB" --project "$PROJ" --net restricted --auth "$auth" -- -p --resume "$sid" 'What codeword did I give you? Reply with only the codeword.' </dev/null 2>&1)"
  if grep -q 'PINEAPPLE-42' <<<"$out"; then ok "$name: --resume continues the conversation in a new container"; else nok "$name: --resume continues the conversation" "$out"; fi
  out="$("$SB" --project "$PROJ" --net restricted --auth "$auth" -- -p --continue 'Repeat the codeword once more, only the codeword.' </dev/null 2>&1)"
  if grep -q 'PINEAPPLE-42' <<<"$out"; then ok "$name: --continue picks up the latest session for this project"; else nok "$name: --continue in same project" "$out"; fi
  out="$("$SB" --project "$PROJ2" --net restricted --auth "$auth" -- -p --continue 'If I gave you a codeword earlier, reply with it; otherwise reply NONE.' </dev/null 2>&1)"
  if ! grep -q 'PINEAPPLE-42' <<<"$out"; then ok "$name: other project does not resume this project's session"; else nok "$name: session isolation between projects" "$out"; fi
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
