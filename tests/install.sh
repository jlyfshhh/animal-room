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

# --clarity is gone; it must now fail like any other unknown flag.
if bash "$root/install.sh" --clarity --dry-run >/dev/null 2>&1; then
  echo "The retired --clarity flag should be rejected." >&2
  exit 1
fi

if bash "$root/install.sh" --unknown >/dev/null 2>&1; then
  echo "Unknown arguments should fail." >&2
  exit 1
fi

# ── Reliability harness ------------------------------------------------------
#
# Everything below runs the real unified installer. Only the child installers,
# Docker daemon, HTTP endpoints, and host facts are deterministic stand-ins.
# This lets CI exercise failure and rollback paths without changing its host.

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fake_bin="$work/bin"
fixtures="$work/fixtures"
mkdir -p "$fake_bin" "$fixtures"

cat >"$fake_bin/sudo" <<'SH'
#!/usr/bin/env bash
set -e
[[ "${1:-}" != -n ]] || shift
export TEST_VIA_SUDO=1
exec "$@"
SH

cat >"$fake_bin/dpkg" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == --print-architecture ]] && { echo arm64; exit 0; }
exit 1
SH

cat >"$fake_bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat >"$fake_bin/usermod" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat >"$fake_bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat >"$fake_bin/hostname" <<'SH'
#!/usr/bin/env bash
echo haven-test
SH

cat >"$fake_bin/ip" <<'SH'
#!/usr/bin/env bash
if [[ "${TEST_NO_PRIVATE_IP:-false}" == true ]]; then
  exit 0
fi
printf '2: eth0    inet %s/24 brd 192.168.50.255 scope global eth0\n' "${TEST_LAN_IP:-192.168.50.20}"
SH

cat >"$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state="${TEST_DOCKER_STATE:?}"
mkdir -p "$state"
printf 'sudo=%s bask_port=%s shed_port=%s cwd=%s docker %s\n' \
  "${TEST_VIA_SUDO:-0}" "${BASK_PORT:-unset}" "${SHED_PORT:-unset}" "$PWD" "$*" >>"$state/docker.log"

if [[ "${TEST_DOCKER_SUDO_ONLY:-false}" == true && "${TEST_VIA_SUDO:-0}" != 1 ]]; then
  if [[ "${1:-}" == compose && "${2:-}" == version ]]; then
    exit 0
  fi
  exit 1
fi

read_value() {
  local file="$1" fallback="${2:-}"
  [[ -f "$file" ]] && cat "$file" || printf '%s' "$fallback"
}

command="${1:-}"
shift || true
case "$command" in
  info)
    exit 0
    ;;
  inspect)
    format=""
    if [[ "${1:-}" == --format ]]; then
      format="$2"
      app="$3"
    else
      app="${1:-}"
    fi
    [[ "$(read_value "$state/$app.exists" false)" == true ]] || exit 1
    case "$format" in
      '') exit 0 ;;
      *'.Config.Image'*) read_value "$state/$app.image_ref" "ghcr.io/example/$app:latest" ;;
      *'.Image}}'*) read_value "$state/$app.image_id" "sha256:new-$app" ;;
      *'.State.Running'*) read_value "$state/$app.running" true ;;
      *'.State.OOMKilled'*) read_value "$state/$app.oom" false ;;
      *'.State.Health'*) read_value "$state/$app.health" healthy ;;
      *) exit 1 ;;
    esac
    ;;
  image)
    [[ "${1:-}" == tag ]]
    image_id="$2"
    image_ref="$3"
    for app in bask shed; do
      if [[ "$(read_value "$state/$app.image_ref")" == "$image_ref" ]]; then
        printf '%s' "$image_id" >"$state/$app.tagged_id"
      fi
    done
    ;;
  compose)
    subcommand="${1:-}"
    shift || true
    [[ "$subcommand" != version ]] || exit 0
    app="$(basename "$PWD")"
    case "$subcommand" in
      pull)
        printf 'sha256:new-%s' "$app" >"$state/$app.pending_id"
        ;;
      up)
        image_id="$(read_value "$state/$app.tagged_id" "$(read_value "$state/$app.pending_id" "sha256:new-$app")")"
        rm -f "$state/$app.tagged_id"
        printf true >"$state/$app.exists"
        printf true >"$state/$app.running"
        printf '%s' "$image_id" >"$state/$app.image_id"
        [[ -f "$state/$app.image_ref" ]] || printf 'ghcr.io/example/%s:latest' "$app" >"$state/$app.image_ref"
        if [[ "${TEST_DOCKER_FAIL_APP:-}" == "$app" && "$image_id" == "sha256:new-$app" ]]; then
          if [[ "${TEST_DOCKER_FAILURE_KIND:-oom}" == oom ]]; then
            printf true >"$state/$app.oom"
            printf false >"$state/$app.running"
          else
            printf false >"$state/$app.oom"
            printf unhealthy >"$state/$app.health"
          fi
        else
          printf false >"$state/$app.oom"
          printf healthy >"$state/$app.health"
        fi
        if [[ "$app" == bask && "${TEST_SKIP_SCANNER:-false}" != true ]]; then
          printf true >"$state/bask-scanner.exists"
          printf true >"$state/bask-scanner.running"
          printf false >"$state/bask-scanner.oom"
          printf healthy >"$state/bask-scanner.health"
        fi
        ;;
      down)
        printf false >"$state/$app.exists"
        printf false >"$state/$app.running"
        if [[ "$app" == bask ]]; then
          printf false >"$state/bask-scanner.exists"
          printf false >"$state/bask-scanner.running"
        fi
        ;;
      stop)
        printf false >"$state/$app.running"
        ;;
      *)
        echo "Unexpected fake compose command: $subcommand" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Unexpected fake Docker command: $command" >&2
    exit 1
    ;;
esac
SH

cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state="${TEST_DOCKER_STATE:?}"
url="${!#}"
if [[ "$url" == */api/health ]]; then
  port="${url#http://127.0.0.1:}"
  port="${port%%/*}"
  if [[ "$port" == "${TEST_BASK_PORT:-8080}" ]]; then app=bask; else app=shed; fi
  code=503
  if [[ "$(cat "$state/$app.exists" 2>/dev/null || echo false)" == true &&
        "$(cat "$state/$app.running" 2>/dev/null || echo false)" == true &&
        "$(cat "$state/$app.oom" 2>/dev/null || echo false)" != true &&
        "$(cat "$state/$app.health" 2>/dev/null || echo healthy)" != unhealthy ]]; then
    code=200
  fi
  [[ "$*" != *"%{http_code}"* ]] || printf '%s' "$code"
  exit 0
fi
if [[ "$url" == */api/room-dashboard ]]; then
  port="${url#http://127.0.0.1:}"
  port="${port%%/*}"
  [[ "$port" == "${TEST_BASK_PORT:-8080}" ]] || exit 1
  if [[ "${TEST_BRIDGE_FAIL:-false}" == true ]]; then
    printf '{"shed":{"available":false}}\n'
  else
    printf '{"shed":{"available":true}}\n'
  fi
  exit 0
fi
echo "Unexpected fake curl URL: $url" >&2
exit 1
SH

cat >"$fixtures/bask-installer.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="${BASK_INSTALL_DIR:?}"
mkdir -p "$dir/data"
if [[ ! -f "$dir/.env" ]]; then
  printf 'BASK_PORT=8080\nBASK_DATA_PATH=./data\n' >"$dir/.env"
fi
printf 'services:\n  bask:\n    image: ghcr.io/example/bask:latest\n' >"$dir/compose.yaml"
if docker info >/dev/null 2>&1; then cmd=(docker); else cmd=(sudo docker); fi
(cd "$dir" && "${cmd[@]}" compose pull -q && "${cmd[@]}" compose up -d)
SH

cat >"$fixtures/shed-installer.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="${SHED_INSTALL_DIR:?}"
mkdir -p "$dir/data" "$dir/backups"
if [[ ! -f "$dir/.env" ]]; then
  printf 'SHED_PORT=3000\nSHED_DATA_PATH=./data\nSHED_DISPLAY_TOKEN=test-display-token\n' >"$dir/.env"
fi
printf 'services:\n  shed:\n    image: ghcr.io/example/shed:latest\n' >"$dir/compose.yaml"
if docker info >/dev/null 2>&1; then cmd=(docker); else cmd=(sudo docker); fi
(cd "$dir" && "${cmd[@]}" compose pull -q && "${cmd[@]}" compose up -d)
SH

chmod +x "$fake_bin"/* "$fixtures"/*

write_meminfo() {
  local file="$1" kib="$2"
  printf 'MemTotal:       %s kB\nMemAvailable:   %s kB\n' "$kib" "$((kib / 2))" >"$file"
}

run_fixture_install() {
  local scenario="$1"
  shift
  env \
    PATH="$fake_bin:/usr/bin:/bin" \
    ANIMAL_ROOM_MEMINFO_PATH="$scenario/meminfo" \
    ANIMAL_ROOM_HEALTH_ATTEMPTS=2 \
    ANIMAL_ROOM_HEALTH_INTERVAL=0 \
    ANIMAL_ROOM_BASK_INSTALLER="$fixtures/bask-installer.sh" \
    ANIMAL_ROOM_SHED_INSTALLER="$fixtures/shed-installer.sh" \
    TEST_DOCKER_STATE="$scenario/docker" \
    TEST_NO_PRIVATE_IP="${TEST_NO_PRIVATE_IP:-false}" \
    TEST_DOCKER_SUDO_ONLY="${TEST_DOCKER_SUDO_ONLY:-false}" \
    TEST_DOCKER_FAIL_APP="${TEST_DOCKER_FAIL_APP:-}" \
    TEST_DOCKER_FAILURE_KIND="${TEST_DOCKER_FAILURE_KIND:-oom}" \
    TEST_BRIDGE_FAIL="${TEST_BRIDGE_FAIL:-false}" \
    TEST_SKIP_SCANNER="${TEST_SKIP_SCANNER:-false}" \
    TEST_BASK_PORT="${TEST_BASK_PORT:-8080}" \
    TEST_SHED_PORT="${TEST_SHED_PORT:-3000}" \
    bash "$root/install.sh" --install-root "$scenario/apps" "$@"
}

seed_running_app() {
  local scenario="$1" app="$2" port_key="$3" port="$4"
  local dir="$scenario/apps/$app" state="$scenario/docker"
  mkdir -p "$dir/data" "$state"
  printf 'records-for-%s\n' "$app" >"$dir/data/sentinel.db"
  printf '%s=%s\nORIGINAL_CONFIG=%s\n' "$port_key" "$port" "$app" >"$dir/.env"
  [[ "$app" != shed ]] || printf 'SHED_DISPLAY_TOKEN=old-display-token\n' >>"$dir/.env"
  printf 'services:\n  %s:\n    image: ghcr.io/example/%s:latest # original\n' "$app" "$app" >"$dir/compose.yaml"
  printf true >"$state/$app.exists"
  printf true >"$state/$app.running"
  printf false >"$state/$app.oom"
  printf healthy >"$state/$app.health"
  printf 'sha256:old-%s' "$app" >"$state/$app.image_id"
  printf 'ghcr.io/example/%s:latest' "$app" >"$state/$app.image_ref"
}

# Docker publishes each distribution under its own codenames, so resolving the
# wrong family 404s inside apt with an error that explains nothing. Ubuntu
# derivatives are covered by UBUNTU_CODENAME rather than by being enumerated.
# Every expected codename below is one Docker actually publishes.
osrel="$work/os-release"
mkdir -p "$osrel"
write_os_release() {
  printf '%s\n' "$2" >"$osrel/$1"
}
write_os_release debian 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
ID=debian
VERSION_CODENAME=trixie'
write_os_release ubuntu 'PRETTY_NAME="Ubuntu 24.04.1 LTS"
ID=ubuntu
ID_LIKE=debian
VERSION_CODENAME=noble
UBUNTU_CODENAME=noble'
write_os_release mint 'PRETTY_NAME="Linux Mint 22"
ID=linuxmint
ID_LIKE=ubuntu
VERSION_CODENAME=wilma
UBUNTU_CODENAME=noble'
write_os_release fedora 'PRETTY_NAME="Fedora Linux 41"
ID=fedora'

check_docker_source() {
  local fixture="$1" expected="$2" actual
  actual="$(ANIMAL_ROOM_OS_RELEASE_PATH="$osrel/$fixture" bash "$root/install.sh" --print-docker-source)"
  case "$actual" in
    *"$expected"*) ;;
    *) echo "$fixture resolved to '$actual', expected to contain '$expected'." >&2; exit 1 ;;
  esac
}
check_docker_source debian "linux/debian trixie"
check_docker_source ubuntu "linux/ubuntu noble"
# Mint's own codename ("wilma") is in no Docker repository; its Ubuntu base is.
check_docker_source mint "linux/ubuntu noble"
if ANIMAL_ROOM_OS_RELEASE_PATH="$osrel/fedora" bash "$root/install.sh" --print-docker-source >/dev/null 2>&1; then
  echo "Fedora should not resolve to a Docker repository." >&2
  exit 1
fi

# Shed and Haven must fail before making changes on a host with too little free
# memory. Bask alone is explicitly allowed and must complete on the same fixture.
# The gate is MemAvailable, not MemTotal: a 1 GB board running a desktop passes
# any MemTotal check and then dies at container start, which is the exact
# failure this preflight exists to prevent.
low="$work/low-memory"
mkdir -p "$low"
write_meminfo "$low/meminfo" 524288
for selection_flag in --shed --haven; do
  if run_fixture_install "$low" "$selection_flag" >"$low/output" 2>&1; then
    echo "$selection_flag should refuse a 512 MB host." >&2
    exit 1
  fi
  grep -q "of free memory" "$low/output" || { echo "$selection_flag did not explain its RAM requirement." >&2; exit 1; }
done
[[ ! -e "$low/apps/shed" ]] || { echo "Low-memory preflight touched Shed's install directory." >&2; exit 1; }
run_fixture_install "$low" --bask >/dev/null
[[ "$(cat "$low/docker/bask.running")" == true ]] || { echo "Bask did not start on the low-memory fixture." >&2; exit 1; }

# No RFC1918 address is a normal state during early boot. It must fall back to
# mDNS instead of exiting because grep returned 1 under pipefail.
no_ip="$work/no-ip"
mkdir -p "$no_ip"
write_meminfo "$no_ip/meminfo" 2097152
no_ip_output="$(TEST_NO_PRIVATE_IP=true run_fixture_install "$no_ip" --bask)"
grep -q 'http://haven-test.local:8080' <<<"$no_ip_output" || { echo "No-IP fallback address was not printed." >&2; exit 1; }

# Existing .env ports control the host endpoints, Haven bridge, and summary.
ports="$work/custom-ports"
mkdir -p "$ports/apps/bask/data" "$ports/apps/shed/data"
write_meminfo "$ports/meminfo" 2097152
printf 'BASK_PORT=8181\nBASK_DATA_PATH=./data\n' >"$ports/apps/bask/.env"
printf 'SHED_PORT=3333\nSHED_DATA_PATH=./data\nSHED_DISPLAY_TOKEN=test-display-token\n' >"$ports/apps/shed/.env"
ports_output="$(TEST_BASK_PORT=8181 TEST_SHED_PORT=3333 run_fixture_install "$ports" --haven)"
grep -q '192.168.50.20:8181' <<<"$ports_output" || { echo "Custom Bask port was not printed." >&2; exit 1; }
grep -q '192.168.50.20:3333' <<<"$ports_output" || { echo "Custom Shed port was not printed." >&2; exit 1; }
grep -q '^SHED_DISPLAY_URL=http://host.docker.internal:3333/api/display$' "$ports/apps/bask/.env" || {
  echo "Haven did not wire Bask to Shed's custom port." >&2
  exit 1
}

# A newly installed Docker daemon commonly works only through sudo until the
# next login. Every unified-installer Docker operation must follow that path.
sudo_only="$work/sudo-only"
mkdir -p "$sudo_only"
write_meminfo "$sudo_only/meminfo" 2097152
TEST_DOCKER_SUDO_ONLY=true run_fixture_install "$sudo_only" --shed >/dev/null
grep -q 'sudo=1 .*docker compose up' "$sudo_only/docker/docker.log" || {
  echo "The sudo-only Docker path was not used for Compose." >&2
  exit 1
}

# An OOM during an update restores the prior config, exact image ID, and
# running state. The database sentinel is never part of the rollback operation.
oom="$work/oom"
mkdir -p "$oom"
write_meminfo "$oom/meminfo" 2097152
seed_running_app "$oom" bask BASK_PORT 8080
cp "$oom/apps/bask/.env" "$oom/original.env"
cp "$oom/apps/bask/compose.yaml" "$oom/original.compose"
if BASK_PORT=8181 TEST_BASK_PORT=8181 TEST_DOCKER_FAIL_APP=bask TEST_DOCKER_FAILURE_KIND=oom \
  run_fixture_install "$oom" --bask >"$oom/output" 2>&1; then
  echo "An OOM update should fail." >&2
  exit 1
fi
cmp "$oom/original.env" "$oom/apps/bask/.env" || { echo "OOM rollback did not restore .env." >&2; exit 1; }
cmp "$oom/original.compose" "$oom/apps/bask/compose.yaml" || { echo "OOM rollback did not restore Compose." >&2; exit 1; }
[[ "$(cat "$oom/docker/bask.image_id")" == sha256:old-bask ]] || { echo "OOM rollback did not restore the prior image." >&2; exit 1; }
[[ "$(cat "$oom/docker/bask.running")" == true ]] || { echo "OOM rollback did not restart the prior container." >&2; exit 1; }
[[ "$(cat "$oom/apps/bask/data/sentinel.db")" == records-for-bask ]] || { echo "OOM rollback altered Bask data." >&2; exit 1; }
grep -q 'bask_port=unset .*docker compose up -d --no-build --pull never' "$oom/docker/docker.log" || {
  echo "OOM rollback reused the failed update's port override." >&2
  exit 1
}

# An unhealthy first install is stopped, but its bind-mounted data is retained
# so the operator can diagnose or retry it.
unhealthy="$work/unhealthy"
mkdir -p "$unhealthy/apps/shed/data"
write_meminfo "$unhealthy/meminfo" 2097152
printf 'do-not-delete\n' >"$unhealthy/apps/shed/data/sentinel.db"
if TEST_DOCKER_FAIL_APP=shed TEST_DOCKER_FAILURE_KIND=unhealthy run_fixture_install "$unhealthy" --shed >"$unhealthy/output" 2>&1; then
  echo "An unhealthy install should fail." >&2
  exit 1
fi
[[ "$(cat "$unhealthy/docker/shed.exists")" == false ]] || { echo "Failed new Shed container was left installed." >&2; exit 1; }
[[ "$(cat "$unhealthy/apps/shed/data/sentinel.db")" == do-not-delete ]] || { echo "Unhealthy rollback altered Shed data." >&2; exit 1; }

# The web page being healthy is insufficient if the receive-only Bluetooth
# worker never started: the dashboard would look alive while sensor data ages
# out. A Bask install therefore requires both split services.
missing_scanner="$work/missing-scanner"
mkdir -p "$missing_scanner"
write_meminfo "$missing_scanner/meminfo" 2097152
if TEST_SKIP_SCANNER=true run_fixture_install "$missing_scanner" --bask >"$missing_scanner/output" 2>&1; then
  echo "Bask without its scanner should fail verification." >&2
  exit 1
fi
grep -q 'scanner container was not created' "$missing_scanner/output" || {
  echo "Missing scanner failure was not explained." >&2
  exit 1
}

# Both apps can be healthy while the read-only integration is broken. Haven is
# not complete until Bask itself reports Shed available, and that failure must
# roll both services back.
bridge="$work/bridge"
mkdir -p "$bridge"
write_meminfo "$bridge/meminfo" 2097152
seed_running_app "$bridge" bask BASK_PORT 8080
seed_running_app "$bridge" shed SHED_PORT 3000
cp "$bridge/apps/bask/.env" "$bridge/bask.env"
cp "$bridge/apps/shed/.env" "$bridge/shed.env"
if TEST_BRIDGE_FAIL=true run_fixture_install "$bridge" --haven >"$bridge/output" 2>&1; then
  echo "A broken Haven bridge should fail." >&2
  exit 1
fi
for app in bask shed; do
  [[ "$(cat "$bridge/docker/$app.image_id")" == "sha256:old-$app" ]] || { echo "Bridge rollback missed $app's image." >&2; exit 1; }
  [[ "$(cat "$bridge/docker/$app.running")" == true ]] || { echo "Bridge rollback did not restart $app." >&2; exit 1; }
  [[ "$(cat "$bridge/apps/$app/data/sentinel.db")" == "records-for-$app" ]] || { echo "Bridge rollback altered $app data." >&2; exit 1; }
done
cmp "$bridge/bask.env" "$bridge/apps/bask/.env" || { echo "Bridge rollback did not restore Bask settings." >&2; exit 1; }
cmp "$bridge/shed.env" "$bridge/apps/shed/.env" || { echo "Bridge rollback did not restore Shed settings." >&2; exit 1; }

# Re-running a healthy Haven install is the supported update path. Persistent
# records must survive it byte-for-byte.
repeat="$work/idempotent"
mkdir -p "$repeat"
write_meminfo "$repeat/meminfo" 2097152
run_fixture_install "$repeat" --haven >/dev/null
printf 'keeper-history\n' >"$repeat/apps/shed/data/sentinel.db"
printf 'sensor-history\n' >"$repeat/apps/bask/data/sentinel.db"
before="$(cksum "$repeat/apps/shed/data/sentinel.db" "$repeat/apps/bask/data/sentinel.db")"
run_fixture_install "$repeat" --haven >/dev/null
after="$(cksum "$repeat/apps/shed/data/sentinel.db" "$repeat/apps/bask/data/sentinel.db")"
[[ "$before" == "$after" ]] || { echo "Reinstall changed persistent application data." >&2; exit 1; }

echo "Unified installer tests passed."
