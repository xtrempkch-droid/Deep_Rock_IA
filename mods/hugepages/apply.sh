#!/usr/bin/env bash
# Aplica a mod hugepages (delega para a implementação local).
# Aceita --dry-run, --yes, --mode always|madvise|never e --static.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${HERE}/hugepages.sh" "$@"
