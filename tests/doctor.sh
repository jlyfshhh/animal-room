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

echo "Diagnostics tests passed."
