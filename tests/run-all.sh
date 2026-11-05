#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -m unittest discover -s "$ROOT/tests" -p 'test_native_fleet.py' -v
for test in "$ROOT"/tests/test-*.sh; do
  bash "$test"
done
