#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true

if [ "$cmd" = "update-lockfile" ]; then
  echo "update-lockfile called"
  touch "${APPENV_MARKER:-.appenv_update_lockfile_called}"
  exit 0
fi

echo "appenv stub: unknown command: $cmd"
exit 1
