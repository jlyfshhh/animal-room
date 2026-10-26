#!/usr/bin/env bash
# The scheduled backup wrapper must never report a failed backup as a success.
#
# Regression for the 2026-10 finding: Shed's own backup command was rejected,
# yet the wrapper printed "backed up shed", exited zero, and listed Shed as
# succeeded — while the only fresh files in the destination were .env copies.
# Every case below injects a failure and asserts it is visible: a non-zero exit,
# an error on stderr, the failure recorded in status.json, and no success line.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper="$root/scripts/animal-app-backup"
# Present in the local multi-repo checkout, absent in this repository's own CI.
real_shed_backup="$root/../husbandry-app/scripts/backup.sh"

command -v python3 >/dev/null 2>&1 || { echo "These tests need python3."; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

home="$work/home"          # stands in for the directory the apps were installed into
dest="$work/dest"          # stands in for the dedicated backup mount
out="$work/stdout"
err="$work/stderr"
stub_log="$work/child-log"
status_json="$dest/status.json"
code=0

# ── Test doubles ─────────────────────────────────────────────────────────────
mkdir -p "$work/bin" "$work/bin-install-fails"
# `mountpoint`: a path is a mount point only if FAKE_MOUNTS lists it.
cat >"$work/bin/mountpoint" <<'STUB'
#!/bin/sh
[ "$1" = "-q" ] && shift
printf '%s\n' "${FAKE_MOUNTS:-}" | grep -qxF -- "$1"
STUB
# `install` that cannot write: the settings copy is the only thing that uses it.
cat >"$work/bin-install-fails/install" <<'STUB'
#!/bin/sh
echo "install: simulated write failure" >&2
exit 1
STUB
chmod +x "$work/bin/mountpoint" "$work/bin-install-fails/install"

write_child() {
  mkdir -p "$home/$1/scripts"
  cat >"$home/$1/scripts/backup.sh" <<'STUB'
#!/usr/bin/env bash
# Stand-in for an app's own backup command; STUB_MODE_<APP> picks the behaviour.
app="$(basename "$(cd "$(dirname "$0")/.." && pwd)")"
mode_var="STUB_MODE_$(printf '%s' "$app" | tr a-z A-Z)"
mode="${!mode_var:-ok}"
case "$app" in
  shed) target="${SHED_BACKUP_PATH:?}"; ext=sqlite ;;
  *)    target="${BASK_BACKUP_PATH:?}"; ext=tar.gz ;;
esac
printf '%s SHED_ALLOW_EXTERNAL_PATHS=%s BASK_ALLOW_EXTERNAL_PATHS=%s\n' "$app" \
  "${SHED_ALLOW_EXTERNAL_PATHS-unset}" "${BASK_ALLOW_EXTERNAL_PATHS-unset}" >>"${STUB_LOG:?}"
archive="$target/$app-$(date +%Y%m%d-%H%M%S)-$$.$ext"
case "$mode" in
  ok)      printf 'database contents\n' >"$archive"; echo "$archive" ;;
  fail)    echo "SHED_BACKUP_PATH resolves outside the install. Set SHED_ALLOW_EXTERNAL_PATHS=true only for a dedicated, pre-created mount." >&2; exit 1 ;;
  exit3)   echo "simulated failure" >&2; exit 3 ;;
  nothing) echo "all done" ;;                       # exits 0, leaves no archive
  empty)   : >"$archive"; echo "$archive" ;;        # exits 0, leaves an empty archive
esac
STUB
  chmod +x "$home/$1/scripts/backup.sh"
}

# A fresh install with both apps and an empty destination.
reset() {
  rm -rf "$home" "$dest" "$work/empty-home" "$work/elsewhere" "$work/mnt"
  mkdir -p "$home" "$dest" "$work/empty-home" "$work/elsewhere" "$work/mnt"
  write_child shed
  write_child bask
  printf 'SHED_TIME_ZONE=UTC\nSHED_ALLOW_EXTERNAL_PATHS=false\n' >"$home/shed/.env"
  status_json="$dest/status.json"
  rm -f "$stub_log"
  unset STUB_MODE_SHED STUB_MODE_BASK
}

run_wrapper() {
  code=0
  env -u ANIMAL_ROOM_HOME -u ANIMAL_BACKUP_ROOT -u ANIMAL_BACKUP_REQUIRE_MOUNT \
      -u ANIMAL_BACKUP_ALLOW_EXTERNAL -u ANIMAL_BACKUP_APPS -u ANIMAL_BACKUP_KEEP \
      -u ANIMAL_BACKUP_STATUS -u SHED_ALLOW_EXTERNAL_PATHS -u BASK_ALLOW_EXTERNAL_PATHS \
      PATH="$work/bin:$PATH" HOME="$home" STUB_LOG="$stub_log" FAKE_MOUNTS="" \
      ANIMAL_ROOM_HOME="$home" ANIMAL_BACKUP_ROOT="$dest" ANIMAL_BACKUP_STATUS="$status_json" \
      "$@" bash "$wrapper" >"$out" 2>"$err" || code=$?
}

# ── Assertions ───────────────────────────────────────────────────────────────
fail_test() {
  echo "$1" >&2
  echo "--- stdout:" >&2; sed 's/^/    /' "$out" >&2
  echo "--- stderr:" >&2; sed 's/^/    /' "$err" >&2
  exit 1
}
status_expr() {
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
    "$status_json" "$1"
}
expect_json() {
  local actual
  actual="$(status_expr "$1")"
  [ "$actual" = "$2" ] || fail_test "status.json: $1 was $actual, expected $2"
}
expect_exit() { [ "$code" -eq "$1" ] || fail_test "$2 (exit status $code, expected $1)"; }
expect_out() { grep -qF -- "$1" "$out" || fail_test "stdout is missing: $1"; }
expect_no_out() { ! grep -qF -- "$1" "$out" || fail_test "stdout must not contain: $1"; }
expect_err() { grep -qF -- "$1" "$err" || fail_test "stderr is missing: $1"; }
child_ran() { [ -s "$stub_log" ]; }

# A failed Shed run must be observable and must not look like a success.
assert_shed_failed() {
  [ "$code" -ne 0 ] || fail_test "$1: the wrapper exited 0 although Shed's backup failed"
  expect_no_out "backed up shed"
  expect_no_out "all backups complete"
  expect_json "d['ok']" False
  expect_json "'shed' in d['succeeded']" False
  expect_json "any(f.startswith('shed') for f in d['failed'])" True
}

# ── A clean run reports success, and counts data apart from settings ─────────
reset
run_wrapper
expect_exit 0 "a clean run should succeed"
expect_out "backed up shed"
expect_out "backed up bask"
expect_out "all backups complete"
expect_json "d['ok']" True
expect_json "sorted(d['succeeded'])" "['bask', 'shed']"
expect_json "d['failed']" "[]"
expect_json "d['apps']['shed']['archives']" 1
expect_json "d['apps']['shed']['settings_copies']" 1
expect_json "d['apps']['shed']['latest'].endswith('.sqlite')" True
expect_json "d['apps']['shed']['latest_settings'].endswith('.env')" True
expect_json "d['apps']['bask']['archives']" 1
expect_json "d['apps']['bask']['settings_copies']" 0
env_copy="$(find "$dest/shed" -name '*.env' | head -n 1)"
mode="$(stat -c '%a' "$env_copy" 2>/dev/null || stat -f '%Lp' "$env_copy")"
[ "$mode" = 600 ] || { echo "The settings copy is mode $mode, expected 600." >&2; exit 1; }
echo "  a clean run succeeds and counts databases separately from settings copies"

# ── (a) A failing child backup command ───────────────────────────────────────
reset
export STUB_MODE_SHED=fail
run_wrapper
assert_shed_failed "child failure"
expect_err "shed: database backup command failed (exit 1)"
expect_err "resolves outside"                    # the child's own reason reaches the log
expect_err "ANIMAL_BACKUP_ALLOW_EXTERNAL"       # and the fix is named
expect_out "backed up bask"                      # the other app is still backed up
expect_json "d['succeeded']" "['bask']"
# The settings copy was written, which is exactly what used to masquerade as a
# backup. It must not count as one.
expect_json "d['apps']['shed']['settings_copies']" 1
expect_json "d['apps']['shed']['archives']" 0
[ -z "$(find "$dest/shed" -name '*.sqlite')" ] || fail_test "no database archive should exist"
echo "  a failing child backup is surfaced and is not reported as success"

reset
export STUB_MODE_SHED=exit3
run_wrapper
assert_shed_failed "child exit status"
expect_err "(exit 3)"
echo "  the child's exit status is propagated"

# ── Exit 0 with nothing to show for it ───────────────────────────────────────
reset
export STUB_MODE_SHED=nothing
run_wrapper
assert_shed_failed "zero database archives"
expect_err "left no new database archive"
echo "  a backup that produced zero database archives is not a success"

reset
# The incident's state: an old database copy, fresh settings copies, and a
# backup command that produces nothing new. An old archive is not a new backup.
mkdir -p "$dest/shed"
printf 'old\n' >"$dest/shed/shed-20260831-000000.sqlite"
export STUB_MODE_SHED=nothing
run_wrapper
assert_shed_failed "stale database archive"
expect_json "d['apps']['shed']['settings_copies']" 1
echo "  fresh settings copies beside a stale database archive do not count as a backup"

reset
export STUB_MODE_SHED=empty
run_wrapper
assert_shed_failed "empty archive"
expect_err "is empty"
echo "  an empty archive is not a success"

# ── (b) A failing settings copy ──────────────────────────────────────────────
reset
run_wrapper PATH="$work/bin-install-fails:$work/bin:$PATH"
assert_shed_failed "settings copy failure"
expect_err "settings copy"
expect_out "backed up bask"
expect_json "d['succeeded']" "['bask']"
expect_json "d['apps']['shed']['archives']" 1          # the database copy itself worked
expect_json "d['apps']['shed']['settings_copies']" 0   # the settings copy did not
echo "  a failing settings copy fails the app and is counted apart from the database"

# ── (c) A missing or unmounted destination ───────────────────────────────────
reset
rm -rf "$dest"
status_json="$work/elsewhere/status.json"
run_wrapper
[ "$code" -ne 0 ] || fail_test "a missing destination was reported as success"
expect_err "does not exist"
expect_no_out "backed up"
expect_no_out "all backups complete"
child_ran && fail_test "a backup ran with no destination"
[ ! -e "$dest" ] || fail_test "the missing destination was manufactured on the wrong device"
expect_json "d['ok']" False
expect_json "len(d['failed']) > 0" True
expect_json "d['succeeded']" "[]"
echo "  a missing destination fails, creates nothing, and is recorded"

reset
run_wrapper ANIMAL_BACKUP_REQUIRE_MOUNT="$dest"
[ "$code" -ne 0 ] || fail_test "an unmounted destination was reported as success"
expect_err "is not mounted"
expect_no_out "backed up"
child_ran && fail_test "a backup ran onto an unmounted destination"
[ -z "$(ls -A "$dest")" ] || fail_test "files were written to the unmounted destination"
echo "  an unmounted destination fails and nothing is written to it"

reset
status_json="$work/elsewhere/status.json"
run_wrapper ANIMAL_BACKUP_REQUIRE_MOUNT="$dest"
[ "$code" -ne 0 ] || fail_test "an unmounted destination was reported as success"
expect_json "d['ok']" False
expect_json "any('not mounted' in f for f in d['failed'])" True
[ -z "$(ls -A "$dest")" ] || fail_test "files were written to the unmounted destination"
echo "  an unmounted destination is recorded when the status file lives elsewhere"

reset
run_wrapper ANIMAL_BACKUP_REQUIRE_MOUNT="$work/mnt" FAKE_MOUNTS="$work/mnt"
[ "$code" -ne 0 ] || fail_test "a destination outside the required mount was accepted"
expect_err "not inside the required mount"
child_ran && fail_test "a backup ran onto a destination outside the mount"
echo "  a destination outside the required mount is refused"

# ── A per-app destination may not escape the backup root through a symlink ────
# Regression for the 2026-10 F12/F01 finding: the per-app directory was a
# symlink pointing off the verified device, so the app's backup command wrote a
# valid database AND the settings copy OUTSIDE the trusted root, and retention
# could delete files out there too. The run returned non-zero only AFTER the
# data had already escaped — a late failure is not mount safety. Each case below
# asserts that nothing is created or removed outside the root.
reset
outside="$work/outside"
rm -rf "$outside"; mkdir -p "$outside"
rm -rf "$dest/shed"
ln -s "$outside" "$dest/shed"
run_wrapper ANIMAL_BACKUP_APPS=shed
[ "$code" -ne 0 ] || fail_test "a symlinked destination was reported as success"
expect_err "symlink"
expect_json "d['ok']" False
expect_json "'shed' in d['succeeded']" False
expect_json "any(f.startswith('shed') for f in d['failed'])" True
child_ran && fail_test "the backup command ran against a symlinked destination"
[ -z "$(find "$outside" -type f)" ] \
  || fail_test "a database or settings copy was written outside the backup root through a symlink"
echo "  a symlinked per-app destination is refused before anything is written outside the root"

# The same must hold for retention: deleting through a symlinked per-app
# directory would reach off the verified device.
reset
outside="$work/outside"
rm -rf "$outside"; mkdir -p "$outside"
printf 'old\n' >"$outside/shed-20200101-000000.sqlite"
printf 'old\n' >"$outside/shed-20200102-000000.sqlite"
touch -t 202001010000 "$outside/shed-20200101-000000.sqlite"
touch -t 202001020000 "$outside/shed-20200102-000000.sqlite"
rm -rf "$dest/shed"
ln -s "$outside" "$dest/shed"
run_wrapper ANIMAL_BACKUP_APPS=shed
[ "$code" -ne 0 ] || fail_test "retention accepted a symlinked destination"
expect_err "refusing to delete through it"
[ -e "$outside/shed-20200101-000000.sqlite" ] \
  || fail_test "retention deleted a file outside the backup root through a symlink"
[ -e "$outside/shed-20200102-000000.sqlite" ] \
  || fail_test "retention deleted a file outside the backup root through a symlink"
echo "  retention refuses to delete through a symlinked per-app destination"

# ── Install root comes from configuration or the installer's default ─────────
reset
run_wrapper ANIMAL_ROOM_HOME=
expect_exit 0 "the install root should default to the user's home, as install.sh does"
expect_json "sorted(d['succeeded'])" "['bask', 'shed']"
echo "  the install root defaults to the installer's default, the user's home"

reset
run_wrapper ANIMAL_ROOM_HOME= HOME="$work/empty-home"
[ "$code" -ne 0 ] || fail_test "finding no installed apps was reported as success"
expect_err "ANIMAL_ROOM_HOME"
expect_no_out "all backups complete"
expect_json "d['ok']" False
expect_json "d['succeeded']" "[]"
echo "  finding no installed apps fails instead of silently skipping everything"

reset
run_wrapper ANIMAL_ROOM_HOME="$work/not-a-directory"
[ "$code" -ne 0 ] || fail_test "a nonexistent install root was accepted"
expect_err "ANIMAL_ROOM_HOME"
child_ran && fail_test "a backup ran without a valid install root"
echo "  a nonexistent install root is refused"

# ── The external-path opt-in is explicit, scoped, and tied to a verified mount ─
reset
run_wrapper
expect_exit 0 "the default run should work"
grep -q '^shed SHED_ALLOW_EXTERNAL_PATHS=unset BASK_ALLOW_EXTERNAL_PATHS=unset$' "$stub_log" \
  || fail_test "the wrapper altered the apps' path validation without being asked"
echo "  without the opt-in, the apps' own path validation is left exactly as configured"

reset
run_wrapper ANIMAL_BACKUP_ALLOW_EXTERNAL=true ANIMAL_BACKUP_REQUIRE_MOUNT="$dest" FAKE_MOUNTS="$dest"
expect_exit 0 "the explicit opt-in on a verified mount should work"
# Each backup command receives only its own app's opt-in.
grep -q '^shed SHED_ALLOW_EXTERNAL_PATHS=true BASK_ALLOW_EXTERNAL_PATHS=unset$' "$stub_log" \
  || fail_test "Shed was not given exactly its own explicit opt-in"
grep -q '^bask SHED_ALLOW_EXTERNAL_PATHS=unset BASK_ALLOW_EXTERNAL_PATHS=true$' "$stub_log" \
  || fail_test "Bask was not given exactly its own explicit opt-in"
expect_json "d['ok']" True
echo "  the explicit opt-in is passed to the backup commands for a verified mount"

reset
run_wrapper ANIMAL_BACKUP_ALLOW_EXTERNAL=true
[ "$code" -ne 0 ] || fail_test "the opt-in was accepted without a mount to verify"
expect_err "only accepted together with ANIMAL_BACKUP_REQUIRE_MOUNT"
child_ran && fail_test "a backup ran with an unverified external opt-in"
echo "  the opt-in is refused unless a mount is required and verified"

reset
run_wrapper ANIMAL_BACKUP_ALLOW_EXTERNAL=maybe
[ "$code" -ne 0 ] || fail_test "a malformed opt-in was accepted"
expect_err "must be true or false"
echo "  a malformed opt-in is refused"

# ── Existing guarantees: independence, skipping, retention ───────────────────
reset
rm -rf "$home/bask"
run_wrapper
expect_exit 0 "an uninstalled app is skipped, not failed"
expect_out "skipping bask"
expect_json "d['succeeded']" "['shed']"
expect_json "d['skipped']" "['bask']"
echo "  an uninstalled app is skipped rather than failed"

reset
run_wrapper ANIMAL_BACKUP_APPS="shed ghost"
[ "$code" -ne 0 ] || fail_test "an unknown app was reported as success"
expect_err "no backup routine for 'ghost'"
expect_json "d['succeeded']" "['shed']"
expect_json "any(f.startswith('ghost') for f in d['failed'])" True
echo "  an unknown app is a failure and does not stop the others"

reset
mkdir -p "$dest/shed"
printf 'old\n' >"$dest/shed/shed-20200101-000000.sqlite"
printf 'old\n' >"$dest/shed/shed-20200102-000000.sqlite"
touch -t 202001010000 "$dest/shed/shed-20200101-000000.sqlite"
touch -t 202001020000 "$dest/shed/shed-20200102-000000.sqlite"
export STUB_MODE_SHED=fail
run_wrapper
assert_shed_failed "retention with a failing app"
[ ! -e "$dest/shed/shed-20200101-000000.sqlite" ] || fail_test "retention did not run after a failure"
[ -e "$dest/shed/shed-20200102-000000.sqlite" ] || fail_test "retention removed the newest archive"
echo "  retention still runs after a failure and keeps the newest archive"

# ── The real Shed backup command, as in the incident ─────────────────────────
if [ -f "$real_shed_backup" ] && command -v sqlite3 >/dev/null 2>&1; then
  reset
  rm -rf "$home/bask"
  d1="$home/shed/data/v3/d1/miniflare-D1DatabaseObject"
  live="$d1/faaf2b0445ab934c3aac48ddf0cdfade8f9bac050be98993748742cdd2cb05fb.sqlite"
  mkdir -p "$d1"
  sqlite3 "$live" "CREATE TABLE animals(id TEXT); CREATE TABLE care_schedules(id TEXT); CREATE TABLE husbandry_events(id TEXT); INSERT INTO animals VALUES('resident');" >/dev/null
  cp "$real_shed_backup" "$home/shed/scripts/backup.sh"
  chmod +x "$home/shed/scripts/backup.sh"

  # No opt-in: the real guard rejects the external destination.
  run_wrapper ANIMAL_BACKUP_APPS=shed
  assert_shed_failed "real Shed backup, no opt-in"
  expect_err "resolves outside"
  expect_json "d['apps']['shed']['archives']" 0
  expect_json "d['apps']['shed']['settings_copies']" 1   # only the settings copy exists
  echo "  the real Shed command rejecting the destination is reported as a failure"

  # Explicit opt-in on a verified mount: a real, verified database archive.
  run_wrapper ANIMAL_BACKUP_APPS=shed ANIMAL_BACKUP_ALLOW_EXTERNAL=true \
    ANIMAL_BACKUP_REQUIRE_MOUNT="$dest" FAKE_MOUNTS="$dest"
  expect_exit 0 "the real Shed backup with the explicit opt-in should succeed"
  expect_out "backed up shed"
  expect_json "d['apps']['shed']['archives']" 1
  archive="$(find "$dest/shed" -name '*.sqlite' | head -n 1)"
  [ -n "$archive" ] || fail_test "no database archive was written"
  [ "$(sqlite3 "$archive" 'PRAGMA integrity_check;')" = ok ] || fail_test "the archive failed its integrity check"
  [ "$(sqlite3 "$archive" 'SELECT COUNT(*) FROM animals;')" = 1 ] || fail_test "the archive is missing the live data"
  echo "  the real Shed command succeeds with the explicit opt-in and writes a verified archive"
else
  echo "  note: skipping the real Shed backup command cases — husbandry-app is not checked out beside this repository"
fi

echo "Backup wrapper tests passed."
