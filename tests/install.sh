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
# `ip -o link show eth0` is how the installer learns the MAC to quote for a
# DHCP reservation; `ip -4 -o addr show` is how it learns the address.
if [[ "$*" == *"link show"* ]]; then
  [[ "${TEST_NO_MAC:-false}" == true ]] && exit 0
  printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000\\    link/ether b8:27:eb:4f:1a:c9 brd ff:ff:ff:ff:ff:ff\n'
  exit 0
fi
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
# The URL is whichever argument is one; the installer puts `-o FILE` after it.
url=""
out=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -o) out="${args[i + 1]:-}" ;;
    http://*|https://*) url="${args[i]}" ;;
  esac
done
# Child-installer downloads. TEST_DOWNLOAD_MODE says how the transfer goes wrong.
# "partial" and "syntax" write a script whose first line records that it ran, so
# a test can tell executed from merely downloaded.
if [[ "$url" == */get-bask.sh || "$url" == */get-shed.sh ]]; then
  app="${url##*/get-}"
  app="${app%.sh}"
  marker="${TEST_PAYLOAD_MARKER:?}"
  printf '%s\n' "$url" >>"$state/downloads.log"
  case "${TEST_DOWNLOAD_MODE:-ok}" in
    ok) cp "${TEST_FIXTURES:?}/$app-installer.sh" "$out" ;;
    partial)
      # A complete, valid prefix of a script, then the connection drops: curl -f
      # exits 22 and leaves the file behind.
      printf '#!/usr/bin/env bash\nprintf "ran\\n" >>%q\n' "$marker" >"$out"
      exit 22
      ;;
    syntax)
      printf '#!/usr/bin/env bash\nprintf "ran\\n" >>%q\nif true; then\n' "$marker" >"$out"
      ;;
    empty) : >"$out" ;;
    missing) ;;
    *) echo "Unknown TEST_DOWNLOAD_MODE" >&2; exit 1 ;;
  esac
  exit 0
fi
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

# A child that has already changed the install by the time it fails.
cat >"$fixtures/bask-installer-exit7.sh" <<'SH'
#!/usr/bin/env bash
dir="${BASK_INSTALL_DIR:?}"
printf 'ran\n' >>"${TEST_PAYLOAD_MARKER:?}"
printf 'BASK_PORT=9999\nCHILD_MUTATION=1\n' >"$dir/.env"
printf 'services:\n  bask:\n    image: ghcr.io/example/bask:child-mutated\n' >"$dir/compose.yaml"
exit 7
SH

# Records that it ran before the syntax error, so a parse that was skipped shows.
cat >"$fixtures/bask-installer-bad-syntax.sh" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' >>"${TEST_PAYLOAD_MARKER:?}"
if true; then
SH

: >"$fixtures/bask-installer-empty.sh"

chmod +x "$fake_bin"/* "$fixtures"/*

write_meminfo() {
  local file="$1" kib="$2"
  printf 'MemTotal:       %s kB\nMemAvailable:   %s kB\n' "$kib" "$((kib / 2))" >"$file"
}

# MemAvailable set directly, for boards where the running apps already hold some.
write_meminfo_available() {
  local file="$1" total_mb="$2" available_mb="$3"
  printf 'MemTotal:       %s kB\nMemAvailable:   %s kB\n' \
    "$((total_mb * 1024))" "$((available_mb * 1024))" >"$file"
}

run_fixture_install() {
  local scenario="$1"
  shift
  env \
    PATH="$fake_bin:/usr/bin:/bin" \
    ANIMAL_ROOM_MEMINFO_PATH="$scenario/meminfo" \
    ANIMAL_ROOM_HEALTH_ATTEMPTS=2 \
    ANIMAL_ROOM_HEALTH_INTERVAL=0 \
    ANIMAL_ROOM_BASK_INSTALLER="${TEST_BASK_INSTALLER:-$fixtures/bask-installer.sh}" \
    ANIMAL_ROOM_SHED_INSTALLER="${TEST_SHED_INSTALLER:-$fixtures/shed-installer.sh}" \
    TEST_FIXTURES="$fixtures" \
    TEST_DOWNLOAD_MODE="${TEST_DOWNLOAD_MODE:-ok}" \
    TEST_PAYLOAD_MARKER="${TEST_PAYLOAD_MARKER:-$scenario/payload-ran}" \
    TEST_DOCKER_STATE="$scenario/docker" \
    TEST_NO_PRIVATE_IP="${TEST_NO_PRIVATE_IP:-false}" \
    TEST_NO_MAC="${TEST_NO_MAC:-false}" \
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

# ── Update-aware memory preflight ---------------------------------------------
#
# MemAvailable is measured while an already-running app still holds its memory,
# but Compose stops the old container before it starts the replacement. A board
# that passed the first install therefore has *less* free memory on the rerun,
# and the supported rerun-to-update must not be refused for that. What each app
# holds when running is credited; the requirement is summed across every selected
# app rather than taken from the largest; and none of it may touch a service
# before the backup and rollback protection exist.
#
#   fresh:  bask 240   shed 400   bask+shed 640   haven 650 (its own floor)
#   update: bask 80    shed 245   bask+shed 325 / 480 (one running)   haven 335
#
# memory_case NAME AVAILABLE_MB pass|refuse "RUNNING APPS" -- install flags...
memory_case() {
  local name="$1" available="$2" outcome="$3" running="$4" app status
  shift 5
  local dir="$work/mem-$name"
  mkdir -p "$dir"
  write_meminfo_available "$dir/meminfo" 512 "$available"
  for app in $running; do
    case "$app" in
      bask) seed_running_app "$dir" bask BASK_PORT 8080 ;;
      shed) seed_running_app "$dir" shed SHED_PORT 3000 ;;
      stopped-bask)
        seed_running_app "$dir" bask BASK_PORT 8080
        printf false >"$dir/docker/bask.running"
        ;;
    esac
  done
  for app in bask shed; do
    [[ ! -f "$dir/apps/$app/.env" ]] || cp "$dir/apps/$app/.env" "$dir/$app.env.before"
  done

  if run_fixture_install "$dir" "$@" >"$dir/output" 2>&1; then status=pass; else status=refuse; fi
  [[ "$status" == "$outcome" ]] || {
    echo "memory case '$name' (${available} MB free, running: ${running:-none}): expected $outcome, got $status." >&2
    cat "$dir/output" >&2
    exit 1
  }
  if [[ "$outcome" == refuse ]]; then
    grep -q "of free memory" "$dir/output" || { echo "memory case '$name' did not explain its RAM requirement." >&2; exit 1; }
    # Refused before anything was changed or stopped, so nothing needs rolling back.
    if grep -q 'docker compose' "$dir/docker/docker.log" 2>/dev/null; then
      echo "memory case '$name' ran Compose although the preflight refused it." >&2
      exit 1
    fi
    for app in $running; do
      app="${app#stopped-}"
      [[ "$(cat "$dir/docker/$app.image_id")" == "sha256:old-$app" ]] || { echo "memory case '$name' replaced $app's image." >&2; exit 1; }
      cmp "$dir/$app.env.before" "$dir/apps/$app/.env" || { echo "memory case '$name' altered $app's settings." >&2; exit 1; }
      [[ "$(cat "$dir/apps/$app/data/sentinel.db")" == "records-for-$app" ]] || { echo "memory case '$name' altered $app's data." >&2; exit 1; }
    done
    for app in $running; do
      [[ "$app" == stopped-* ]] || [[ "$(cat "$dir/docker/$app.running")" == true ]] ||
        { echo "memory case '$name' stopped $app before refusing." >&2; exit 1; }
    done
  else
    grep -q "Installation complete" "$dir/output" || { echo "memory case '$name' did not finish." >&2; exit 1; }
  fi
}

# A fresh install gets the full floor; the boundary is exact.
memory_case fresh-bask-below 239 refuse "" -- --bask
memory_case fresh-bask-at    240 pass   "" -- --bask

# The same 512 MB board, Bask now running and holding ~160 MB of what was free.
# 96 MB free is below the fresh floor yet is a normal, supported update.
memory_case update-bask-small   96 pass   "bask" -- --bask
memory_case update-bask-at      80 pass   "bask" -- --bask
memory_case update-bask-below   79 refuse "bask" -- --bask
[[ "$(cat "$work/mem-update-bask-small/docker/bask.image_id")" == sha256:new-bask ]] ||
  { echo "The small-board update did not actually update Bask." >&2; exit 1; }
grep -q "net of the 160 MB the running Bask" "$work/mem-update-bask-below/output" ||
  { echo "The refusal did not say what the running app was credited." >&2; exit 1; }
# A container that exists but is stopped holds no memory, so earns no credit.
memory_case stopped-bask-small  96 refuse "stopped-bask" -- --bask
# The credit is for the app being updated only: a running Shed does not help Bask.
memory_case update-bask-shed-up 96 refuse "shed" -- --bask

memory_case update-shed-at      245 pass   "shed" -- --shed
memory_case update-shed-below   244 refuse "shed" -- --shed
memory_case fresh-shed-below    399 refuse ""     -- --shed

# --bask --shed runs both containers without naming Haven. The old code took only
# Shed's 400 MB here and let a 512 MB-free board start both.
memory_case dual-fresh-512      512 refuse "" -- --bask --shed
memory_case dual-fresh-639      639 refuse "" -- --bask --shed
memory_case dual-fresh-640      640 pass   "" -- --bask --shed
grep -q "needs about 640 MB" "$work/mem-dual-fresh-639/output" ||
  { echo "Selecting Bask and Shed did not require both apps' memory." >&2; exit 1; }
memory_case dual-update-both-324 324 refuse "bask shed" -- --bask --shed
memory_case dual-update-both-325 325 pass   "bask shed" -- --bask --shed
memory_case dual-update-bask-479 479 refuse "bask" -- --bask --shed
memory_case dual-update-bask-480 480 pass   "bask" -- --bask --shed

# Haven keeps its own combined floor, which sits above the 640 MB sum.
memory_case haven-fresh-649      649 refuse "" -- --haven
memory_case haven-fresh-650      650 pass   "" -- --haven
memory_case haven-update-334     334 refuse "bask shed" -- --haven
memory_case haven-update-335     335 pass   "bask shed" -- --haven

# Passing the preflight on credit is not a promise the update works. If the new
# container is killed, the previous image, settings and running state come back.
squeeze="$work/squeezed-update"
mkdir -p "$squeeze"
write_meminfo_available "$squeeze/meminfo" 512 96
seed_running_app "$squeeze" bask BASK_PORT 8080
cp "$squeeze/apps/bask/.env" "$squeeze/original.env"
cp "$squeeze/apps/bask/compose.yaml" "$squeeze/original.compose"
if TEST_DOCKER_FAIL_APP=bask TEST_DOCKER_FAILURE_KIND=oom run_fixture_install "$squeeze" --bask >"$squeeze/output" 2>&1; then
  echo "An update that is killed for memory should fail." >&2
  exit 1
fi
cmp "$squeeze/original.env" "$squeeze/apps/bask/.env" || { echo "Small-board rollback did not restore .env." >&2; exit 1; }
cmp "$squeeze/original.compose" "$squeeze/apps/bask/compose.yaml" || { echo "Small-board rollback did not restore Compose." >&2; exit 1; }
[[ "$(cat "$squeeze/docker/bask.image_id")" == sha256:old-bask ]] || { echo "Small-board rollback did not restore the prior image." >&2; exit 1; }
[[ "$(cat "$squeeze/docker/bask.running")" == true ]] || { echo "Small-board rollback did not restart Bask." >&2; exit 1; }
[[ "$(cat "$squeeze/apps/bask/data/sentinel.db")" == records-for-bask ]] || { echo "Small-board rollback altered Bask data." >&2; exit 1; }

# The sudo-only path is how the very first install runs; the preflight must not
# need a password-less group membership to be read-only.
sudo_mem="$work/mem-sudo"
mkdir -p "$sudo_mem"
write_meminfo_available "$sudo_mem/meminfo" 512 96
seed_running_app "$sudo_mem" bask BASK_PORT 8080
TEST_DOCKER_SUDO_ONLY=true run_fixture_install "$sudo_mem" --bask >"$sudo_mem/output" 2>&1 ||
  { echo "A sudo-only update on a small board was refused." >&2; cat "$sudo_mem/output" >&2; exit 1; }


# When a LAN address is known, the .local name must not be offered alongside it.
# mDNS fails on Windows without Bonjour and on many Android phones, so printing
# both hands the keeper a choice where one option silently does not load.
with_ip="$work/with-ip"
mkdir -p "$with_ip"
write_meminfo "$with_ip/meminfo" 2097152
with_ip_output="$(run_fixture_install "$with_ip" --bask)"
grep -q 'http://192\.168\.50\.20:8080' <<<"$with_ip_output" ||
  { echo "The LAN address was not printed." >&2; exit 1; }
grep -q '\.local' <<<"$with_ip_output" &&
  { echo "The .local name was offered even though a LAN address is known." >&2; exit 1; }
grep -qi 'reserve it' <<<"$with_ip_output" ||
  { echo "The address-reservation note was not printed." >&2; exit 1; }
grep -q 'b8:27:eb:4f:1a:c9' <<<"$with_ip_output" ||
  { echo "The MAC address for the reservation was not printed." >&2; exit 1; }

# A machine that will not report its MAC still installs; it just loses the
# sentence naming it.
no_mac="$work/no-mac"
mkdir -p "$no_mac"
write_meminfo "$no_mac/meminfo" 2097152
no_mac_output="$(TEST_NO_MAC=true run_fixture_install "$no_mac" --bask)"
grep -qi 'reserve it' <<<"$no_mac_output" ||
  { echo "The reservation note vanished when the MAC was unavailable." >&2; exit 1; }
grep -q 'MAC address' <<<"$no_mac_output" &&
  { echo "An empty MAC was still announced." >&2; exit 1; }

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

# Each app has its own key, they are not interchangeable, and both are shown
# only at install time. A keeper who assumed one key opened both spent a day
# trying each in the other, so the summary names them per app and prints the
# values rather than telling anyone where to go looking.
keys="$work/keeper-keys"
mkdir -p "$keys/apps/bask/data" "$keys/apps/shed/data"
write_meminfo "$keys/meminfo" 2097152
printf 'BASK_PORT=8080\nBASK_DATA_PATH=./data\nBASK_KEEPER_KEY=bask-key-value\n' >"$keys/apps/bask/.env"
printf 'SHED_PORT=3000\nSHED_DATA_PATH=./data\nSHED_BOOTSTRAP_TOKEN=shed-key-value\n' >"$keys/apps/shed/.env"
keys_output="$(run_fixture_install "$keys" --haven)"
grep -qF "Bask:  bask-key-value" <<<"$keys_output" || {
  echo "The summary did not print the Bask Head Keeper key." >&2
  exit 1
}
grep -qF "Shed:  shed-key-value" <<<"$keys_output" || {
  echo "The summary did not print the Shed Head Keeper key." >&2
  exit 1
}
if grep -q '%s' <<<"$keys_output"; then
  echo "The summary printed a printf format string instead of a key." >&2
  exit 1
fi

# A single-app install must not name a key belonging to an app that is not
# there, nor point at a file that will not exist.
solo="$work/keeper-keys-solo"
mkdir -p "$solo/apps/bask/data"
write_meminfo "$solo/meminfo" 2097152
printf 'BASK_PORT=8080\nBASK_DATA_PATH=./data\nBASK_KEEPER_KEY=bask-only-key\n' >"$solo/apps/bask/.env"
solo_output="$(run_fixture_install "$solo" --bask)"
grep -qF "Bask:  bask-only-key" <<<"$solo_output" || {
  echo "A Bask-only install did not print its key." >&2
  exit 1
}
if grep -q "SHED_BOOTSTRAP_TOKEN" <<<"$solo_output"; then
  echo "A Bask-only install pointed at Shed's key file." >&2
  exit 1
fi
grep -qF "https://animalroom.app/support/" <<<"$solo_output" || {
  echo "A successful install did not print the quiet optional-support link." >&2
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

# ── Child-installer validation ------------------------------------------------
#
# The unified installer promises that it finishes a child's download and checks
# it before running anything. run_remote_installer is called as `if ! ...`, which
# turns errexit off inside it, so each of those steps has to be checked explicitly.
# Every failure below must leave nothing executed that was not whole and valid,
# report failure, and run the same rollback as any other failed install.
url_bask="https://installers.example.invalid/get-bask.sh"
url_shed="https://installers.example.invalid/get-shed.sh"

# check_child_rejected LABEL APP INSTALLER MODE EXPECT_RAN [extra]
#   EXPECT_RAN=true when the script legitimately ran (a valid child that fails).
check_child_rejected() {
  local label="$1" app="$2" installer="$3" mode="$4" expect_ran="$5" expected_text="$6"
  local dir="$work/child-$label" other
  mkdir -p "$dir"
  write_meminfo "$dir/meminfo" 2097152
  seed_running_app "$dir" "$app" "$([[ "$app" == bask ]] && echo BASK_PORT || echo SHED_PORT)" \
    "$([[ "$app" == bask ]] && echo 8080 || echo 3000)"
  cp "$dir/apps/$app/.env" "$dir/original.env"
  cp "$dir/apps/$app/compose.yaml" "$dir/original.compose"
  local marker="$dir/payload-ran" status=0
  if [[ "$app" == bask ]]; then
    TEST_PAYLOAD_MARKER="$marker" TEST_DOWNLOAD_MODE="$mode" TEST_BASK_INSTALLER="$installer" \
      run_fixture_install "$dir" --bask >"$dir/output" 2>&1 || status=$?
  else
    TEST_PAYLOAD_MARKER="$marker" TEST_DOWNLOAD_MODE="$mode" TEST_SHED_INSTALLER="$installer" \
      run_fixture_install "$dir" --shed >"$dir/output" 2>&1 || status=$?
  fi

  [[ "$status" -ne 0 ]] || { echo "$label: the installer reported success." >&2; cat "$dir/output" >&2; exit 1; }
  if [[ "$expect_ran" == true ]]; then
    [[ -f "$marker" ]] || { echo "$label: the valid child never ran." >&2; exit 1; }
  else
    [[ ! -e "$marker" ]] || { echo "$label: unvalidated installer data was executed." >&2; cat "$dir/output" >&2; exit 1; }
    # No child ran, so nothing may have pulled or started a new image.
    if grep -q 'docker compose pull' "$dir/docker/docker.log"; then
      echo "$label: Compose pulled an image although no installer ran." >&2
      exit 1
    fi
  fi
  if grep -q "Installation complete" "$dir/output"; then
    echo "$label: a failed child was reported as a completed install." >&2
    exit 1
  fi
  grep -qE -- "$expected_text" "$dir/output" || { echo "$label: the failure was not explained (/$expected_text/)." >&2; cat "$dir/output" >&2; exit 1; }
  # The rollback ran, and it restored everything it is meant to.
  grep -q "Restoring the previous running configuration" "$dir/output" || { echo "$label: rollback did not run." >&2; exit 1; }
  grep -q "previous services were restored" "$dir/output" || { echo "$label: rollback was not reported." >&2; exit 1; }
  cmp "$dir/original.env" "$dir/apps/$app/.env" || { echo "$label: rollback did not restore .env." >&2; exit 1; }
  cmp "$dir/original.compose" "$dir/apps/$app/compose.yaml" || { echo "$label: rollback did not restore Compose." >&2; exit 1; }
  [[ "$(cat "$dir/docker/$app.image_id")" == "sha256:old-$app" ]] || { echo "$label: rollback did not restore the prior image." >&2; exit 1; }
  [[ "$(cat "$dir/docker/$app.running")" == true ]] || { echo "$label: rollback did not leave $app running." >&2; exit 1; }
  [[ "$(cat "$dir/apps/$app/data/sentinel.db")" == "records-for-$app" ]] || { echo "$label: rollback altered $app data." >&2; exit 1; }
}

# 1. The download dies after writing a complete, valid prefix. This is the
#    reproduced defect: the prefix parsed, ran, and the function returned success.
check_child_rejected partial-bask bask "$url_bask" partial false 'Could not download Bask.s installer'
check_child_rejected partial-shed shed "$url_shed" partial false 'Could not download Shed.s installer'
# 2. The download completes but is not a valid script.
check_child_rejected syntax-download bask "$url_bask" syntax false 'failed its syntax check'
check_child_rejected syntax-local bask "$fixtures/bask-installer-bad-syntax.sh" ok false 'failed its syntax check'
# 3. Nothing usable arrived: no file at all, an empty file, a path that is not there.
check_child_rejected missing-download bask "$url_bask" missing false 'missing or empty'
check_child_rejected empty-download bask "$url_bask" empty false 'missing or empty'
check_child_rejected empty-local bask "$fixtures/bask-installer-empty.sh" ok false 'missing or empty'
check_child_rejected missing-local bask "$work/no-such-dir/get-bask.sh" ok false 'was not found'
# 4. A well-formed child that changes the install and then exits nonzero.
check_child_rejected exit-nonzero bask "$fixtures/bask-installer-exit7.sh" ok true "Bask's installer did not finish"

# A fresh install that fails validation leaves no half-installed app behind.
fresh_fail="$work/child-fresh"
mkdir -p "$fresh_fail"
write_meminfo "$fresh_fail/meminfo" 2097152
if TEST_DOWNLOAD_MODE=partial TEST_PAYLOAD_MARKER="$fresh_fail/payload-ran" TEST_BASK_INSTALLER="$url_bask" \
  run_fixture_install "$fresh_fail" --bask >"$fresh_fail/output" 2>&1; then
  echo "A fresh install with a truncated child download should fail." >&2
  exit 1
fi
[[ ! -e "$fresh_fail/payload-ran" ]] || { echo "A truncated fresh download was executed." >&2; exit 1; }
[[ ! -e "$fresh_fail/apps/bask/compose.yaml" && ! -e "$fresh_fail/apps/bask/.env" ]] ||
  { echo "A failed fresh install left Bask's files behind." >&2; exit 1; }
[[ "$(cat "$fresh_fail/docker/bask.exists" 2>/dev/null || echo false)" != true ]] ||
  { echo "A failed fresh install left a Bask container." >&2; exit 1; }

# The second child failing must undo the first, which already updated: a valid
# Bask is installed, then Shed's download is cut short.
pair="$work/child-pair"
mkdir -p "$pair"
write_meminfo "$pair/meminfo" 2097152
seed_running_app "$pair" bask BASK_PORT 8080
seed_running_app "$pair" shed SHED_PORT 3000
for app in bask shed; do
  cp "$pair/apps/$app/.env" "$pair/$app.env"
  cp "$pair/apps/$app/compose.yaml" "$pair/$app.compose"
done
if TEST_DOWNLOAD_MODE=partial TEST_PAYLOAD_MARKER="$pair/payload-ran" TEST_SHED_INSTALLER="$url_shed" \
  run_fixture_install "$pair" --bask --shed >"$pair/output" 2>&1; then
  echo "A truncated Shed download should fail the whole install." >&2
  exit 1
fi
[[ ! -e "$pair/payload-ran" ]] || { echo "Shed's truncated download was executed." >&2; exit 1; }
grep -q "Bask's installer did not finish" "$pair/output" && { echo "Bask was blamed for Shed's download." >&2; exit 1; }
grep -q "Shed's installer did not finish" "$pair/output" || { echo "Shed's failed download was not reported." >&2; exit 1; }
for app in bask shed; do
  [[ "$(cat "$pair/docker/$app.image_id")" == "sha256:old-$app" ]] || { echo "Pair rollback missed $app's image." >&2; exit 1; }
  [[ "$(cat "$pair/docker/$app.running")" == true ]] || { echo "Pair rollback did not restart $app." >&2; exit 1; }
  cmp "$pair/$app.env" "$pair/apps/$app/.env" || { echo "Pair rollback did not restore $app settings." >&2; exit 1; }
  cmp "$pair/$app.compose" "$pair/apps/$app/compose.yaml" || { echo "Pair rollback did not restore $app Compose." >&2; exit 1; }
  [[ "$(cat "$pair/apps/$app/data/sentinel.db")" == "records-for-$app" ]] || { echo "Pair rollback altered $app data." >&2; exit 1; }
done

# And the normal path still works end to end: both children fetched over the
# (stand-in) network, validated, run, and the install verified.
fetched="$work/child-fetched"
mkdir -p "$fetched"
write_meminfo "$fetched/meminfo" 2097152
fetched_output="$(TEST_DOWNLOAD_MODE=ok TEST_BASK_INSTALLER="$url_bask" TEST_SHED_INSTALLER="$url_shed" \
  run_fixture_install "$fetched" --bask --shed 2>&1)"
grep -q "Installation complete" <<<"$fetched_output" || { echo "A fetched install did not complete." >&2; echo "$fetched_output" >&2; exit 1; }
for app in bask shed; do
  [[ "$(cat "$fetched/docker/$app.running")" == true ]] || { echo "A fetched install did not start $app." >&2; exit 1; }
  [[ -f "$fetched/apps/$app/compose.yaml" ]] || { echo "A fetched install did not write $app's files." >&2; exit 1; }
done
# Both came over the stand-in network rather than from a leftover local file.
for url in "$url_bask" "$url_shed"; do
  grep -qxF "$url" "$fetched/docker/downloads.log" || { echo "A fetched install never downloaded $url." >&2; exit 1; }
done

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
