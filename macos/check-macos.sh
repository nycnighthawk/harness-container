#!/bin/bash
# Check that this Mac is ready for claude-mac-sandbox. Prints PASS/WARN/FAIL
# with the fix for anything missing. Run as your normal user.
set -uo pipefail

fail=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
fix()  { printf '       fix: %s\n' "$*"; }

echo "macOS sandbox checks for $(id -un)"
[ "$(uname -s)" = Darwin ] || { bad "not macOS"; exit 1; }
ver="$(sw_vers -productVersion)"; major="${ver%%.*}"
if [ "$major" -ge 13 ]; then pass "macOS $ver"; else bad "macOS $ver (need 13 Ventura or newer)"; fi
[ "$(id -u)" -ne 0 ] && pass "not running as root" || { bad "running as root"; fix "run as your normal user"; }

if [ -x /usr/bin/sandbox-exec ] && /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny file-write* (literal "/private/tmp/.sbx-probe"))' \
     /bin/sh -c 'touch /private/tmp/.sbx-probe' 2>/dev/null; then
  bad "Seatbelt did not block a denied write"
else
  if [ -x /usr/bin/sandbox-exec ] && /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
    pass "Seatbelt (sandbox-exec) enforces profiles"
  else
    bad "sandbox-exec is missing or cannot apply a profile"
    fix "you may already be inside a sandbox (nested sandboxes are not allowed); run from a normal Terminal"
  fi
fi
rm -f /private/tmp/.sbx-probe

if xcode-select -p >/dev/null 2>&1; then pass "developer tools: $(xcode-select -p)"
else bad "Xcode or Command Line Tools not installed"; fix "xcode-select --install   (or install Xcode from the App Store)"; fi
if command -v swift >/dev/null 2>&1; then pass "$(swift --version 2>/dev/null | head -1)"; else warn "swift not found"; fi
if xcodebuild -version >/dev/null 2>&1; then pass "$(xcodebuild -version | head -1)"
else warn "full Xcode not selected (xcodebuild unavailable); Swift packages still build with swift build"
     fix "install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"; fi
command -v git >/dev/null && pass "git $(git --version | awk '{print $3}')" || bad "git not found"

if command -v claude >/dev/null 2>&1; then pass "Claude Code $(claude --version 2>/dev/null | head -1)"
else bad "claude not on PATH"; fix "curl -fsSL https://claude.ai/install.sh | bash   (then open a new terminal)"; fi

if command -v tinyproxy >/dev/null 2>&1; then pass "tinyproxy present (for --net restricted)"
else warn "tinyproxy missing: --net restricted unavailable"; fix "brew install tinyproxy"; fi

for s in claude-sandbox-oauth-token claude-sandbox-anthropic-api-key; do
  if security find-generic-password -a "$(id -un)" -s "$s" >/dev/null 2>&1; then pass "Keychain item '$s' present"; fi
done

echo
if [ "$fail" = 1 ]; then echo "Some checks failed. Fix them and re-run."; exit 1; fi
echo "All required checks passed."
