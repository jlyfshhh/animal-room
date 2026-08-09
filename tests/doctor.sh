#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
doctor="$root/doctor.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A stand-in install whose settings file holds values that must never appear in
# a report someone is about to paste into a chat window.
SECRET_TOKEN="a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
SECRET_CODE="hunter2-not-in-the-report"
# Only shed exists, so the report must also handle bask being absent.
mkdir -p "$work/shed/data"
cat >"$work/shed/.env" <<ENV
SHED_TIME_ZONE=America/New_York
SHED_BOOTSTRAP_TOKEN=$SECRET_TOKEN
SHED_ACCESS_CODE=$SECRET_CODE
SHED_DISPLAY_TOKEN=replace-with-a-separate-long-random-secret
SHED_EMPTY=
ENV
printf 'services:\n  shed:\n    image: busybox\n' >"$work/shed/compose.yaml"

report="$(bash "$doctor" --install-root "$work" 2>&1)"

# The whole point of the script.
for secret in "$SECRET_TOKEN" "$SECRET_CODE"; do
  if grep -qF -- "$secret" <<<"$report"; then
    echo "Diagnostics leaked a secret value from .env." >&2
    exit 1
  fi
done

# Names are reported so the reader can see what is configured; values are not.
grep -q "SHED_BOOTSTRAP_TOKEN" <<<"$report" || { echo "Setting names should be listed." >&2; exit 1; }
grep -q "SHED_EMPTY *empty" <<<"$report" || { echo "An unset value should read as empty." >&2; exit 1; }
grep -q "STILL A PLACEHOLDER" <<<"$report" || { echo "An unreplaced placeholder should be called out." >&2; exit 1; }

# Facts a helper actually needs, on any host.
for expected in "Host" "Docker" "shed" "bask" "Reaching the apps"; do
  grep -qi -- "$expected" <<<"$report" || { echo "Report is missing: $expected" >&2; exit 1; }
done

# The memory read comes from /proc, which only exists on the Linux boards these
# apps target. Assert it where it applies rather than weakening the check.
if [[ -r /proc/meminfo ]]; then
  grep -q "memory total" <<<"$report" || { echo "Report is missing: memory total" >&2; exit 1; }
  grep -q "memory available" <<<"$report" || { echo "Report is missing: memory available" >&2; exit 1; }
else
  echo "note: skipping the /proc memory assertions — not a Linux host."
fi

# An install that is not there must be reported, not crash the run.
grep -q "not present" <<<"$report" || { echo "A missing install should be reported." >&2; exit 1; }

# It must not touch anything.
[[ -f "$work/shed/.env" && -d "$work/shed/data" && -f "$work/shed/compose.yaml" ]] \
  || { echo "Diagnostics modified the install." >&2; exit 1; }

# And it must still work where there is nothing at all to find.
bash "$doctor" --install-root "$work/nowhere" >/dev/null 2>&1 \
  || { echo "Diagnostics should succeed even with no install." >&2; exit 1; }

if bash "$doctor" --unknown-flag >/dev/null 2>&1; then
  echo "Unknown arguments should fail." >&2
  exit 1
fi

# ── The log filters, which the fixture above cannot reach ────────────────────
# These run over container logs. Bask names every sensor after the animal it
# sits with, so a routine line is a record; a crash line can quote a token.
# shellcheck disable=SC1090
DOCTOR_LIB_ONLY=1 source "$doctor"

hostile='ERROR auth failed SHED_BOOTSTRAP_TOKEN=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0 for animal=Achilles'
filtered="$(printf '%s\n' "$hostile" | redact | scrub_readings)"
grep -qF "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0" <<<"$filtered" \
  && { echo "A token in a log line was not redacted." >&2; exit 1; }
grep -qF "Achilles" <<<"$filtered" \
  && { echo "An animal name in a log line was not redacted." >&2; exit 1; }

reading='INFO flushed 10 configured — Taco Warm Side=25.2C/53%, Odysseus Cool Side=25.9C/72%'
scrubbed="$(printf '%s\n' "$reading" | scrub_readings)"
for name in Taco Odysseus; do
  grep -qF "$name" <<<"$scrubbed" && { echo "A sensor reading leaked $name." >&2; exit 1; }
done

# ── QC-28: the fixtures a support paste actually contains ────────────────────
check_redacted() {
  local label="$1" line="$2" must_not="$3"
  local out
  out="$(printf '%s\n' "$line" | redact | scrub_readings)"
  if grep -qF -- "$must_not" <<<"$out"; then
    echo "$label leaked: $out" >&2
    exit 1
  fi
}

check_redacted "a bearer token" \
  'ERROR auth failed: Authorization: Bearer abc123def456ghi789jkl012mno345' 'abc123def456'
check_redacted "basic credentials" \
  'ERROR upstream refused: Authorization: Basic dXNlcjpwYXNzd29yZA==' 'dXNlcjpwYXNzd29yZA'
check_redacted "a JWT" \
  'ERROR token rejected eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.7dGhpc19pc19hX3NpZw' 'eyJzdWIiOiIxIn0'
check_redacted "a cookie header" \
  'ERROR request failed Cookie: bask_keeper=v2.123.deadbeefcafe; other=1' 'deadbeefcafe'
check_redacted "a password containing spaces" \
  'ERROR login failed PASSWORD="correct horse battery staple"' 'correct horse battery'
check_redacted "a token in a query string" \
  'ERROR fetch failed https://ntfy.sh/publish?token=sk_live_9f8e7d6c5b4a' 'sk_live_9f8e7d6c5b4a'
check_redacted "credentials inside a URL" \
  'ERROR could not reach https://admin:hunter2@192.168.1.5/api' 'hunter2'
check_redacted "an email address" \
  'ERROR notify failed for keeper@example.com' 'keeper@example.com'
check_redacted "a sensor reading" \
  'ERROR range check failed: Achilles Warm Side=92.1C/51%' 'Achilles'
check_redacted "a MAC address" \
  'ERROR pairing failed for A4:C1:38:E9:AA:45' 'A4:C1:38:E9:AA:45'
echo "  every credential fixture is redacted"

# The false positive that let routine access logs through: `OOM` matched the
# `oom` inside `room-dashboard`, and those log lines carry animal names.
problem_filter() {
  grep -iE '(^|[^a-z])(error|warn|warning|fatal|critical|exception|traceback|refused|denied|permission|cannot|could not|unable|failed|not found|no such|address already|EADDR[A-Z]*|panic|unhandled|out of memory|oom-killer|oom_kill|killed|segfault)([^a-z]|$)'
}
if printf '%s\n' '127.0.0.1 - GET /room-dashboard?animal=Achilles HTTP/1.1 200' | problem_filter >/dev/null; then
  echo "A routine access log still matches the problem filter." >&2
  exit 1
fi
# And genuine problems must still be reported.
for genuine in 'ERROR something broke' 'container was OOM killed' 'WARNING disk nearly full' \
               'oom-killer invoked' 'Traceback (most recent call last):'; do
  printf '%s\n' "$genuine" | problem_filter >/dev/null \
    || { echo "A genuine problem line was filtered out: $genuine" >&2; exit 1; }
done
echo "  routine logs are excluded while genuine problems still appear"

echo "Diagnostics tests passed."
