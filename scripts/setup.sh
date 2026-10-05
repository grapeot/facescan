#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/setup.sh

Create the project-local uv virtual environment (.venv) and install the
package with its dev extras. Idempotent: safe to run repeatedly.

Environment:
  PYTHON  Optional interpreter passed to `uv venv --python`.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ ! -f pyproject.toml ]; then
  echo "setup: pyproject.toml not found in $root" >&2
  echo "setup: the installable package metadata is missing; cannot create the environment" >&2
  exit 1
fi

if [ ! -d "$root/.venv" ]; then
  if [ -n "${PYTHON:-}" ]; then
    uv venv "$root/.venv" --python "$PYTHON"
  else
    uv venv "$root/.venv"
  fi
fi

# shellcheck disable=SC1091
. "$root/.venv/bin/activate"

uv pip install -e '.[dev]'
echo "setup: environment ready at $root/.venv"
