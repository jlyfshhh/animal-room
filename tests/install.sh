#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

all_output="$(bash "$root/install.sh" --all --dry-run)"
[[ "$all_output" == *"Selected: bask shed haven-dashboard"* ]]
[[ "$all_output" == *"no system or application changes made"* ]]

haven_output="$(bash "$root/install.sh" --haven --dry-run)"
[[ "$haven_output" == *"Selected: bask shed haven-dashboard"* ]]

combo_output="$(bash "$root/install.sh" --bask --shed --dry-run)"
[[ "$combo_output" == *"Selected: bask shed"* ]]
[[ "$combo_output" != *"haven-dashboard"* ]]

legacy_output="$(bash "$root/install.sh" --clarity --dry-run)"
[[ "$legacy_output" == *"Selected: clarity"* ]]

if bash "$root/install.sh" --unknown >/dev/null 2>&1; then
  echo "Unknown arguments should fail." >&2
  exit 1
fi

echo "Unified installer tests passed."
