#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE=${1:-1}

case "$SOURCE" in
  0|1) ;;
  *)
    echo "usage: $0 [0|1]  (0=ROM, 1=live ADS1292)" >&2
    exit 2
    ;;
esac

exec python3 "$SCRIPT_DIR/ecg_web.py" \
  --bit "$SCRIPT_DIR/ecg_bd_wrapper.bit" \
  --window 2000 \
  --analysis-window 2000 \
  --source "$SOURCE"
