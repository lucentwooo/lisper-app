#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x Lisper 2>/dev/null || true
./scripts/build.sh "$@"
open dist/Lisper.app
