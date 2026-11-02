#!/usr/bin/env bash
# Run a CI step; on failure, surface the last lines of output as a GitHub annotation
# (visible in the PR checks UI and via the check-runs API without opening logs).
log="$(mktemp)"
bash -c "$*" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
if [[ $rc -ne 0 ]]; then
  msg="$(tail -n 40 "$log" | sed 's/\x1b\[[0-9;]*m//g' | sed ':a;N;$!ba;s/%/%25/g;s/\r/%0D/g;s/\n/%0A/g')"
  echo "::error title=step failed (exit $rc): ${GITHUB_STEP_NAME:-$1}::${msg}"
fi
exit "$rc"
