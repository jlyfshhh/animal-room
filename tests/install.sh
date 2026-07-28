#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

all_output="$(bash "$root/install.sh" --all --dry-run)"
[[ "$all_output" == *"Selected: bask shed clarity"* ]]
[[ "$all_output" == *"no system or application changes made"* ]]

combo_output="$(bash "$root/install.sh" --bask --clarity --dry-run)"
[[ "$combo_output" == *"Selected: bask clarity"* ]]
[[ "$combo_output" != *"Selected: bask shed"* ]]

if bash "$root/install.sh" --unknown >/dev/null 2>&1; then
  echo "Unknown arguments should fail." >&2
  exit 1
fi

echo "Unified installer tests passed."
