#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
uninstall="$root/uninstall.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Build a stand-in install: records and settings alongside a checkout.
seed_root() {
  local target="$1"
  rm -rf "$target"
  local app
  for app in bask shed; do
    mkdir -p "$target/$app/data" "$target/$app/backups" "$target/$app/.git"
    printf 'records\n' >"$target/$app/data/db.sqlite"
    printf 'old\n' >"$target/$app/backups/old.tar.gz"
    printf 'SECRET=abc\n' >"$target/$app/.env"
    # A real compose file: on a runner that has Docker, the uninstaller will
    # actually parse this, and `services:` with nothing under it is invalid.
    printf 'services:\n  %s:\n    image: busybox\n' "$app" >"$target/$app/compose.yaml"
    printf 'readme\n' >"$target/$app/README.md"
    printf 'config\n' >"$target/$app/.git/config"
  done
}

# --- selection ---------------------------------------------------------------

seed_root "$work/select"
all_output="$(bash "$uninstall" --all --install-root "$work/select" --dry-run --yes)"
[[ "$all_output" == *"About to remove: bask shed"* ]]
[[ "$all_output" == *"would run:"* ]]

shed_output="$(bash "$uninstall" --shed --install-root "$work/select" --dry-run --yes)"
[[ "$shed_output" == *"About to remove: shed"* ]]
[[ "$shed_output" != *"About to remove: bask"* ]]

if bash "$uninstall" --unknown --dry-run >/dev/null 2>&1; then
  echo "Unknown arguments should fail." >&2
  exit 1
fi

# A dry run must leave every file alone.
[[ -f "$work/select/shed/README.md" ]]
[[ -f "$work/select/shed/data/db.sqlite" ]]

# --- default keeps records ---------------------------------------------------

seed_root "$work/keep"
bash "$uninstall" --all --install-root "$work/keep" --yes >/dev/null

for app in bask shed; do
  # The whole point of the default path: records, backups, and settings stay.
  [[ -f "$work/keep/$app/data/db.sqlite" ]] || { echo "$app data was deleted." >&2; exit 1; }
  [[ -f "$work/keep/$app/backups/old.tar.gz" ]] || { echo "$app backups were deleted." >&2; exit 1; }
  [[ -f "$work/keep/$app/.env" ]] || { echo "$app settings were deleted." >&2; exit 1; }
  [[ "$(cat "$work/keep/$app/data/db.sqlite")" == "records" ]] || { echo "$app data changed." >&2; exit 1; }
  # The checkout around them goes.
  [[ ! -e "$work/keep/$app/README.md" ]] || { echo "$app checkout survived." >&2; exit 1; }
  [[ ! -e "$work/keep/$app/.git" ]] || { echo "$app .git survived." >&2; exit 1; }
done

# --- purge backs up before deleting ------------------------------------------

seed_root "$work/purge"
purge_output="$(bash "$uninstall" --shed --install-root "$work/purge" --purge --yes)"

[[ ! -e "$work/purge/shed" ]] || { echo "--purge left the app directory behind." >&2; exit 1; }
[[ -e "$work/purge/bask" ]] || { echo "--purge removed an app that was not selected." >&2; exit 1; }
[[ "$purge_output" == *"backup:"* ]] || { echo "--purge did not report a backup." >&2; exit 1; }

backup="$(find "$work/purge" -maxdepth 1 -name 'shed-backup-*.tar.gz' | head -n 1)"
[[ -n "$backup" ]] || { echo "--purge wrote no backup archive." >&2; exit 1; }

# The archive can contain .env, so it must not be readable by anyone else.
mode="$(stat -c '%a' "$backup" 2>/dev/null || stat -f '%Lp' "$backup")"
[[ "$mode" == "600" ]] || { echo "Backup archive is mode $mode, expected 600." >&2; exit 1; }

# And it has to actually contain the records it claimed to save.
[[ "$(tar -xzOf "$backup" data/db.sqlite)" == "records" ]] || {
  echo "Backup archive does not contain the records." >&2
  exit 1
}

echo "Uninstaller tests passed."
