#!/usr/bin/env bash
# Aplica a mod governor (delega para a implementação local).
# Aceita --dry-run, --yes e --governor performance|powersave|schedutil.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${HERE}/governor.sh" "$@"
