#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
REQ_FILE="$SCRIPT_DIR/requirements.txt"
STAMP_FILE="$VENV_DIR/.deps-ready"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  python3 -m venv "$VENV_DIR"
fi

if [[ ! -f "$STAMP_FILE" || "$REQ_FILE" -nt "$STAMP_FILE" || "$SCRIPT_DIR/clash_verge_helper.py" -nt "$STAMP_FILE" ]]; then
  "$VENV_DIR/bin/pip" install --quiet --disable-pip-version-check -r "$REQ_FILE" 1>&2
  touch "$STAMP_FILE"
fi

exec "$VENV_DIR/bin/python" "$SCRIPT_DIR/clash_verge_helper.py" "$@"
