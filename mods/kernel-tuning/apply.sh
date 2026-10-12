#!/usr/bin/env bash
# Aplica a mod kernel-tuning (delega para a implementação local).
# Aceita --dry-run e --yes, repassados adiante.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${HERE}/kernel-tuning.sh" "$@"
