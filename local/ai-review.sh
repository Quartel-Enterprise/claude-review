#!/usr/bin/env bash
# Delegates to the self-contained skill CLI so clones and `npx skills` share one implementation.
set -euo pipefail
script_path=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")
repo_root=$(cd "$(dirname "$script_path")/.." && pwd)
exec "$repo_root/skills/ai-review/scripts/ai-review.sh" "$@"
