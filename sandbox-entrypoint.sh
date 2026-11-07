#!/usr/bin/env bash
# Container entrypoint: load credentials from mounted podman secrets into the
# process environment (so they never appear in `podman inspect`), then start
# claude, or bash when the first argument is --shell.
set -euo pipefail

load() { # FILE VAR
  if [[ -r "$1" ]]; then
    export "$2"="$(cat "$1")"
  fi
}
load /run/secrets/anthropic_api_key  ANTHROPIC_API_KEY
load /run/secrets/claude_oauth_token CLAUDE_CODE_OAUTH_TOKEN

if [[ "${1:-}" == "--shell" ]]; then
  shift
  exec /bin/bash "$@"
fi
exec claude "$@"
