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

# ── Custom ports ─────────────────────────────────────────────────────────────
# The installer supports BASK_PORT and SHED_PORT, and the container publishes
# whatever they say. A health probe fixed on 3000/8080 would report a healthy
# custom-port install as failed. These run the whole script against a stand-in
# Docker and curl so every way a port can be configured is covered: the
# container's published mapping, the app's .env in each syntax Compose accepts,
# a stale .env that disagrees with the container, a bind address that is not
# localhost, and values that are not usable ports.
fake_bin="$work/fake-bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
# Stand-in daemon. TEST_CONTAINERS names the containers that exist, and
# TEST_PORTS_SHED / TEST_PORTS_BASK are what `docker port` prints for them.
exists() { [[ " ${TEST_CONTAINERS:-} " == *" $1 "* ]]; }
case "${1:-}" in
  --version) echo "Docker version 27.0.0, build test" ;;
  info) exit 0 ;;
  version) echo "27.0.0" ;;
  compose) echo "2.29.0" ;;
  image) echo "linux/arm64" ;;
  logs) exit 0 ;;
  port)
    exists "$2" || exit 1
    var="TEST_PORTS_$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
    printf '%b' "${!var:-}"
    ;;
  inspect)
    exists "$2" || exit 1
    case "${4:-}" in
      *State.Status*) echo running ;;
      *RestartCount*) echo 0 ;;
      *OOMKilled*) echo false ;;
      *ExitCode*) echo 0 ;;
      *State.Health*) echo healthy ;;
      *Config.Image*) echo "ghcr.io/example/$2:latest" ;;
      *State.Pid*) echo 0 ;;
      *) echo ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH

# Answers 200 only for the host:port pairs in TEST_HEALTHY, as a real curl
# prints 000 and fails for a connection nothing is listening on.
cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
url="${!#}"
printf '%s\n' "$url" >>"${TEST_CURL_LOG:?}"
hostport="${url#http://}"
hostport="${hostport%%/*}"
for healthy in ${TEST_HEALTHY:-}; do
  if [[ "$healthy" == "$hostport" ]]; then printf '200'; exit 0; fi
done
printf '000'
exit 7
SH

cat >"$fake_bin/ss" <<'SH'
#!/usr/bin/env bash
printf 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
for port in 22 3000 3333 3444 4040 8080 8181 8282 9999; do
  printf 'LISTEN 0      4096   0.0.0.0:%s      0.0.0.0:*\n' "$port"
done
SH
chmod +x "$fake_bin"/*

new_install() {
  mkdir -p "$1/shed/data" "$1/bask/data"
  printf 'services:\n' >"$1/shed/compose.yaml"
  printf 'services:\n' >"$1/bask/compose.yaml"
  : >"$1/curl.log"
}

run_doctor() {
  PATH="$fake_bin:$PATH" TEST_CURL_LOG="$1/curl.log" bash "$doctor" --install-root "$1" 2>&1
}

section_of() {
  awk -v heading="=== $2 ===" '$0 == heading {inside = 1; next} /^=== / {inside = 0} inside' <<<"$1"
}

expect() {
  local label="$1" text="$2" pattern="$3"
  grep -qE -- "$pattern" <<<"$text" || {
    echo "$label: expected /$pattern/ in:" >&2
    printf '%s\n' "$text" >&2
    exit 1
  }
}

refute() {
  local label="$1" text="$2" pattern="$3"
  if grep -qE -- "$pattern" <<<"$text"; then
    echo "$label: did not expect /$pattern/ in:" >&2
    printf '%s\n' "$text" >&2
    exit 1
  fi
}

# Unit checks on the two parsers every variant goes through.
envfile="$work/parse.env"
printf 'A_PORT=1\nA_PORT="2" # note\nB_PORT=\x27 3 \x27\r\nexport C_PORT=4  # c\nD_PORT=5\r\n' >"$envfile"
[[ "$(env_setting "$envfile" A_PORT)" == 2 ]] || { echo "env_setting: last assignment, quotes and comment." >&2; exit 1; }
[[ "$(env_setting "$envfile" B_PORT)" == " 3 " ]] || { echo "env_setting: quoted value must be kept whole." >&2; exit 1; }
[[ "$(env_setting "$envfile" C_PORT)" == 4 ]] || { echo "env_setting: export and inline comment." >&2; exit 1; }
[[ "$(env_setting "$envfile" D_PORT)" == 5 ]] || { echo "env_setting: CRLF must not leak into the value." >&2; exit 1; }
[[ -z "$(env_setting "$envfile" MISSING_PORT)" ]] || { echo "env_setting: absent key must be empty." >&2; exit 1; }
[[ -z "$(env_setting "$work/no-such.env" A_PORT)" ]] || { echo "env_setting: absent file must be empty." >&2; exit 1; }
[[ "$(clean_port 08181)" == 8181 ]] || { echo "clean_port: leading zeros are not octal." >&2; exit 1; }
for bad in "" 0 65536 99999 123456 80a -1 "8 0" 0x50; do
  if clean_port "$bad" >/dev/null; then
    echo "clean_port accepted '$bad'." >&2
    exit 1
  fi
done

# Defaults: nothing configured and nothing running probes 3000 and 8080.
ports_default="$work/ports-default"
new_install "$ports_default"
printf 'SHED_TIME_ZONE=UTC\n' >"$ports_default/shed/.env"
printf 'BASK_DATA_PATH=./data\n' >"$ports_default/bask/.env"
report="$(TEST_HEALTHY="localhost:3000 localhost:8080" run_doctor "$ports_default")"
expect "default shed" "$(section_of "$report" shed)" 'health check port +3000 \(default\)'
expect "default shed" "$(section_of "$report" shed)" 'local health check +HTTP 200'
expect "default bask" "$(section_of "$report" bask)" 'health check port +8080 \(default\)'
expect "default bask" "$(section_of "$report" bask)" 'local health check +HTTP 200'
echo "  default ports are still probed when nothing is customised"

# Ports named in .env, no container yet: the settings a restart will publish.
ports_env="$work/ports-env"
new_install "$ports_env"
printf 'SHED_PORT=3333\nSHED_BOOTSTRAP_TOKEN=%s\n' "$SECRET_TOKEN" >"$ports_env/shed/.env"
printf 'BASK_PORT=8181\nBASK_KEEPER_KEY=%s\n' "$SECRET_CODE" >"$ports_env/bask/.env"
report="$(TEST_HEALTHY="localhost:3333 localhost:8181" run_doctor "$ports_env")"
expect "env shed" "$(section_of "$report" shed)" 'health check port +3333 \(\.env\)'
expect "env shed" "$(section_of "$report" shed)" 'local health check +HTTP 200'
expect "env bask" "$(section_of "$report" bask)" 'health check port +8181 \(\.env\)'
expect "env bask" "$(section_of "$report" bask)" 'local health check +HTTP 200'
refute "env ports" "$(cat "$ports_env/curl.log")" ':(3000|8080)/'
expect "listening" "$report" 'listening +.*0\.0\.0\.0:3333'
expect "listening" "$report" 'listening +.*0\.0\.0\.0:8181'
refute "listening" "$report" 'listening +.*:(22|9999)( |$)'
for secret in "$SECRET_TOKEN" "$SECRET_CODE"; do
  grep -qF -- "$secret" <<<"$report" && { echo "Reading a port leaked a secret value." >&2; exit 1; }
done
# The same install with a container that exists but is stopped publishes nothing.
report="$(TEST_CONTAINERS="shed bask" TEST_HEALTHY="localhost:3333 localhost:8181" run_doctor "$ports_env")"
expect "stopped shed" "$(section_of "$report" shed)" 'health check port +3333 \(\.env\)'
expect "stopped bask" "$(section_of "$report" bask)" 'health check port +8181 \(\.env\)'
echo "  ports named in .env are probed, and no secret travels with them"

# Ports from the container's published mapping, with no port in .env at all.
ports_map="$work/ports-map"
new_install "$ports_map"
printf 'SHED_TIME_ZONE=UTC\n' >"$ports_map/shed/.env"
printf 'BASK_DATA_PATH=./data\n' >"$ports_map/bask/.env"
report="$(TEST_CONTAINERS="shed bask" \
  TEST_PORTS_SHED='3000/tcp -> 0.0.0.0:3444\n3000/tcp -> [::]:3444\n' \
  TEST_PORTS_BASK='8080/tcp -> 0.0.0.0:8282\n8080/tcp -> [::]:8282\n' \
  TEST_HEALTHY="localhost:3444 localhost:8282" run_doctor "$ports_map")"
expect "mapped shed" "$(section_of "$report" shed)" 'health check port +3444 \(container mapping\)'
expect "mapped shed" "$(section_of "$report" shed)" 'local health check +HTTP 200'
expect "mapped bask" "$(section_of "$report" bask)" 'health check port +8282 \(container mapping\)'
expect "mapped bask" "$(section_of "$report" bask)" 'local health check +HTTP 200'
refute "mapped" "$report" 'port note'
echo "  the container's published port is probed"

# The container is what is reachable, so a stale .env must not decide the probe —
# but the disagreement is worth telling whoever reads the report.
ports_drift="$work/ports-drift"
new_install "$ports_drift"
printf 'SHED_PORT=3333\n' >"$ports_drift/shed/.env"
printf 'BASK_PORT=8181\n' >"$ports_drift/bask/.env"
report="$(TEST_CONTAINERS="shed bask" \
  TEST_PORTS_SHED='3000/tcp -> 0.0.0.0:3444\n' \
  TEST_PORTS_BASK='8080/tcp -> 0.0.0.0:8282\n' \
  TEST_HEALTHY="localhost:3444 localhost:8282" run_doctor "$ports_drift")"
expect "drift shed" "$(section_of "$report" shed)" 'health check port +3444 \(container mapping\)'
expect "drift shed" "$(section_of "$report" shed)" 'port note +.*3333.*3444'
expect "drift shed" "$(section_of "$report" shed)" 'local health check +HTTP 200'
expect "drift bask" "$(section_of "$report" bask)" 'health check port +8282 \(container mapping\)'
expect "drift bask" "$(section_of "$report" bask)" 'port note +.*8181.*8282'
echo "  a stale .env does not override the container, and is flagged"

# Several published ports: the app's own wins, wherever it is listed; with none of
# the app's own, the first published port is used.
ports_multi="$work/ports-multi"
new_install "$ports_multi"
printf 'SHED_TIME_ZONE=UTC\n' >"$ports_multi/shed/.env"
printf 'BASK_DATA_PATH=./data\n' >"$ports_multi/bask/.env"
report="$(TEST_CONTAINERS="shed bask" \
  TEST_PORTS_SHED='9229/tcp -> 127.0.0.1:9229\n3000/tcp -> 0.0.0.0:3444\n' \
  TEST_PORTS_BASK='4000/tcp -> 0.0.0.0:4040\n' \
  TEST_HEALTHY="localhost:3444 localhost:4040" run_doctor "$ports_multi")"
expect "multi shed" "$(section_of "$report" shed)" 'health check port +3444 \(container mapping\)'
expect "multi bask" "$(section_of "$report" bask)" 'health check port +4040 \(container mapping\)'
echo "  the right published port is chosen when there are several"

# Bask can be bound to one address (BASK_BIND_ADDRESS). A service bound to a LAN
# address or to loopback only answers there, so the probe goes to that address.
ports_bind="$work/ports-bind"
new_install "$ports_bind"
printf 'SHED_TIME_ZONE=UTC\n' >"$ports_bind/shed/.env"
printf 'BASK_PORT=8181\nBASK_BIND_ADDRESS=192.168.50.20\n' >"$ports_bind/bask/.env"
report="$(TEST_HEALTHY="localhost:3000 192.168.50.20:8181" run_doctor "$ports_bind")"
expect "bind from .env" "$(section_of "$report" bask)" 'health check port +8181 \(\.env\)'
expect "bind from .env" "$(section_of "$report" bask)" 'local health check +HTTP 200'
grep -q 'http://192\.168\.50\.20:8181/' "$ports_bind/curl.log" || { echo "Bound address from .env was not probed." >&2; exit 1; }
grep -qE '192\.168\.50\.20' <<<"$(section_of "$report" bask)" && { echo "The bind address should not be printed." >&2; exit 1; }
report="$(TEST_CONTAINERS="shed bask" \
  TEST_PORTS_SHED='3000/tcp -> 0.0.0.0:3000\n' \
  TEST_PORTS_BASK='8080/tcp -> 127.0.0.1:8181\n' \
  TEST_HEALTHY="localhost:3000 127.0.0.1:8181" run_doctor "$ports_bind")"
expect "bind from mapping" "$(section_of "$report" bask)" 'health check port +8181 \(container mapping\)'
expect "bind from mapping" "$(section_of "$report" bask)" 'local health check +HTTP 200'
printf 'BASK_PORT=8181\nBASK_BIND_ADDRESS=0.0.0.0\n' >"$ports_bind/bask/.env"
report="$(TEST_HEALTHY="localhost:3000 localhost:8181" run_doctor "$ports_bind")"
expect "wildcard bind" "$(section_of "$report" bask)" 'local health check +HTTP 200'
echo "  a service bound to one address is probed there"

# Every spelling of a port that Compose accepts reads back the same.
ports_syntax="$work/ports-syntax"
new_install "$ports_syntax"
printf 'SHED_TIME_ZONE=UTC\n' >"$ports_syntax/shed/.env"
check_spelling() {
  local label="$1" content="$2"
  printf "$content" >"$ports_syntax/bask/.env"
  : >"$ports_syntax/curl.log"
  report="$(TEST_HEALTHY="localhost:3000 localhost:8181" run_doctor "$ports_syntax")"
  expect "$label" "$(section_of "$report" bask)" 'health check port +8181 \(\.env\)'
  expect "$label" "$(section_of "$report" bask)" 'local health check +HTTP 200'
}
check_spelling "double quotes" 'BASK_PORT="8181"\n'
check_spelling "single quotes" "BASK_PORT='8181'\n"
check_spelling "export prefix" 'export BASK_PORT=8181\n'
check_spelling "inline comment" 'BASK_PORT=8181 # custom\n'
check_spelling "CRLF line ending" 'BASK_PORT=8181\r\n'
check_spelling "no trailing newline" 'BASK_PORT=8181'
check_spelling "last assignment wins" 'BASK_PORT=8080\nBASK_PORT=8181\n'
check_spelling "leading zeros" 'BASK_PORT=08181\n'
check_spelling "surrounding settings" 'BASK_DATA_PATH=./data\nBASK_PORT=8181\nBASK_KEEPER_KEY=not-in-report\n'
refute "settings spelling" "$report" 'not-in-report'
echo "  every .env spelling of a port is understood"

# Something that is not a port falls back to the default, says so, and never
# echoes the value — an unusable setting can be anything, including a secret
# pasted on the wrong line.
ports_bad="$work/ports-bad"
new_install "$ports_bad"
printf 'SHED_TIME_ZONE=UTC\n' >"$ports_bad/shed/.env"
for bad in not-a-port-s3cr3t 0 65536 99999 123456 80a; do
  printf 'BASK_PORT=%s\n' "$bad" >"$ports_bad/bask/.env"
  report="$(TEST_HEALTHY="localhost:3000 localhost:8080" run_doctor "$ports_bad")"
  expect "bad port $bad" "$(section_of "$report" bask)" 'health check port +8080 \(default\)'
  expect "bad port $bad" "$(section_of "$report" bask)" 'port note +.*BASK_PORT.*not a usable port.*using the default 8080'
  expect "bad port $bad" "$(section_of "$report" bask)" 'local health check +HTTP 200'
  # The note is fixed text; if it were built from the setting it would differ.
  [[ "$(section_of "$report" bask | sed -n 's/^  port note  *//p')" == \
     "BASK_PORT in .env is not a usable port number (1-65535); using the default 8080" ]] || {
    echo "The note for unusable port '$bad' was not the fixed text." >&2
    exit 1
  }
done
grep -qF 's3cr3t' <<<"$report" && { echo "An unusable port setting was echoed." >&2; exit 1; }
printf 'BASK_PORT=\n' >"$ports_bad/bask/.env"
report="$(TEST_HEALTHY="localhost:3000 localhost:8080" run_doctor "$ports_bad")"
expect "empty port" "$(section_of "$report" bask)" 'health check port +8080 \(default\)'
refute "empty port" "$(section_of "$report" bask)" 'port note'
echo "  unusable port settings fall back to the default without being printed"

# A healthy install still reports a failure when the app really is down.
ports_down="$work/ports-down"
new_install "$ports_down"
printf 'SHED_PORT=3333\n' >"$ports_down/shed/.env"
printf 'BASK_PORT=8181\n' >"$ports_down/bask/.env"
report="$(TEST_HEALTHY="" run_doctor "$ports_down")"
expect "down shed" "$(section_of "$report" shed)" 'local health check +HTTP 000'
expect "down bask" "$(section_of "$report" bask)" 'local health check +HTTP 000'
echo "  an app that is really down is still reported as down"

echo "Diagnostics tests passed."
