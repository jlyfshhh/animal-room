#!/usr/bin/env bash
# Animal Room: collect troubleshooting facts about an install.
#
# Prints a report you can paste to whoever is helping you. It reads state only —
# it starts, stops, and changes nothing.
#
# It deliberately does not collect: the contents of your .env, any access code,
# token, password or API key, your animals' records, your database, or your
# public IP address. Secret settings are reported as "set" or "empty" and never
# by value, and the log excerpts are filtered for anything token-shaped.
set -uo pipefail

install_root="${ANIMAL_ROOM_HOME:-$HOME}"
version="1"

while (($#)); do
  case "$1" in
    --install-root)
      shift
      [[ $# -gt 0 ]] || { echo "--install-root needs a path." >&2; exit 1; }
      install_root="$1"
      ;;
    -h|--help)
      echo "Usage: doctor.sh [--install-root PATH]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

section() { printf '\n=== %s ===\n' "$1"; }
item() { printf '  %-22s %s\n' "$1" "${2:-unknown}"; }

# Anything token-shaped is replaced before it reaches the report: long hex or
# base64 runs, and the value side of any key whose name suggests a secret.
redact() {
  sed -E \
    -e 's/[A-Fa-f0-9]{24,}/<redacted>/g' \
    -e 's/[A-Za-z0-9+\/]{40,}={0,2}/<redacted>/g' \
    -e 's/(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|ACCESS_?CODE|AUTHORIZATION|COOKIE)([\"'"'"']?\s*[:=]\s*)[^[:space:],;}\"]*/\1\2<redacted>/gI'
}

# Sensors are named after the animals they sit with, so a reading is a record.
# Belt and braces behind the log filter above, in case a problem line quotes one.
scrub_readings() {
  sed -E \
    -e 's/[A-Za-z0-9_'"'"'-]+([ _][A-Za-z0-9_'"'"'-]+)*[ ]?=[ ]?-?[0-9]+(\.[0-9]+)?[ ]?(C|F|%)(\/-?[0-9]+(\.[0-9]+)?%?)?/<reading redacted>/g' \
    -e 's/(animal|enclosure|sensor|species)([\"'"'"']?\s*[:=]\s*)[^[:space:],;}\"]*/\1\2<redacted>/gI'
}

# Lets the tests exercise the filters directly. The redaction that matters most
# runs over container logs, which a fixture without a running container never
# reaches — so without this hook, turning it off would go unnoticed.
if [[ -n "${DOCTOR_LIB_ONLY:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

printf 'Animal Room diagnostics (script v%s)\n' "$version"
printf 'generated %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
printf 'No secrets, records, or public addresses are included.\n'

# ── Host ─────────────────────────────────────────────────────────────────────
section "Host"
if [[ -r /proc/device-tree/model ]]; then
  item "board" "$(tr -d '\0' < /proc/device-tree/model)"
fi
if [[ -r /etc/os-release ]]; then
  item "os" "$(. /etc/os-release; echo "$PRETTY_NAME")"
fi
item "kernel" "$(uname -sr)"
item "architecture" "$(uname -m)"
item "userspace bits" "$(getconf LONG_BIT 2>/dev/null) bit"

if [[ -r /proc/meminfo ]]; then
  mem_total=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
  mem_avail=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)
  swap_total=$(awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo)
  item "memory total" "${mem_total} MB"
  item "memory available" "${mem_avail} MB"
  item "swap total" "${swap_total} MB"
  # Shed's worker peaks near 390 MB. Below that it will be killed while starting,
  # which looks exactly like "installed fine, site can't be reached".
  if [[ "$mem_total" -lt 900 ]]; then
    printf '  ** This board has %s MB of RAM. Shed needs about 400 MB free just to\n' "$mem_total"
    printf '     start, so 1 GB or more is the realistic minimum. Bask is far lighter\n'
    printf '     and is fine here.\n'
  fi
fi
item "load average" "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
item "disk free (install)" "$(df -h "$install_root" 2>/dev/null | awk 'NR==2{print $4" free of "$2}')"

# cgroup v2 exposes controllers in a different place than v1, and a Pi that has
# never had cgroup_enable=memory set in cmdline.txt will silently ignore
# Docker's --memory. Worth knowing which you have.
if [[ -r /sys/fs/cgroup/cgroup.controllers ]]; then
  if grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
    item "cgroup memory" "enabled (v2)"
  else
    item "cgroup memory" "DISABLED (v2) — memory limits are ignored"
  fi
elif [[ -r /proc/cgroups ]]; then
  cgroup_state=$(awk '/^memory/{print ($4==1 ? "enabled (v1)" : "DISABLED (v1) — memory limits are ignored")}' /proc/cgroups)
  item "cgroup memory" "${cgroup_state:-not reported}"
fi

# ── Docker ───────────────────────────────────────────────────────────────────
section "Docker"
if command -v docker >/dev/null 2>&1; then
  item "docker" "$(docker --version 2>/dev/null)"
  item "compose" "$(docker compose version --short 2>/dev/null || echo 'not installed')"
  if docker info >/dev/null 2>&1; then
    docker_cmd=(docker); item "access" "ok as $(id -un)"
  elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    docker_cmd=(sudo docker); item "access" "needs sudo"
  else
    docker_cmd=(); item "access" "UNAVAILABLE to $(id -un)"
  fi
  if ((${#docker_cmd[@]})); then
    item "server version" "$("${docker_cmd[@]}" version --format '{{.Server.Version}}' 2>/dev/null)"
  fi
else
  docker_cmd=()
  item "docker" "NOT INSTALLED"
fi

# ── Apps ─────────────────────────────────────────────────────────────────────
for app in shed bask; do
  dir="$install_root/$app"
  section "$app"
  if [[ ! -d "$dir" ]]; then
    item "install dir" "not present ($dir)"
    continue
  fi
  item "install dir" "$dir"
  item "compose file" "$([[ -f "$dir/compose.yaml" || -f "$dir/docker-compose.yml" ]] && echo present || echo MISSING)"
  # Computed in steps: the container writes as root, so du can hit a directory
  # it cannot read, and under `set -o pipefail` that would append a second line
  # to the value.
  if [[ -d "$dir/data" ]]; then
    data_size=$(du -sh "$dir/data" 2>/dev/null | cut -f1)
    item "data dir" "${data_size:-present (size unreadable)}"
  else
    item "data dir" "missing"
  fi

  # Settings are reported by key only. Values never leave the machine.
  if [[ -f "$dir/.env" ]]; then
    printf '  settings (%s/.env) — names and whether a value is set, never the value:\n' "$app"
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^[[:space:]]*# || -z "${key// }" ]] && continue
      if [[ -z "${value// }" ]]; then state="empty"
      elif [[ "$value" == replace-with-* ]]; then state="STILL A PLACEHOLDER"
      else state="set"; fi
      printf '      %-26s %s\n' "$key" "$state"
    done < "$dir/.env"
  else
    item ".env" "MISSING"
  fi

  if ((${#docker_cmd[@]})); then
    status=$("${docker_cmd[@]}" inspect "$app" --format '{{.State.Status}}' 2>/dev/null)
    if [[ -n "$status" ]]; then
      item "container" "$status"
      item "restarts" "$("${docker_cmd[@]}" inspect "$app" --format '{{.RestartCount}}' 2>/dev/null)"
      # The single most useful line in this whole report on a small board.
      item "OOM killed" "$("${docker_cmd[@]}" inspect "$app" --format '{{.State.OOMKilled}}' 2>/dev/null)"
      item "exit code" "$("${docker_cmd[@]}" inspect "$app" --format '{{.State.ExitCode}}' 2>/dev/null)"
      item "health" "$("${docker_cmd[@]}" inspect "$app" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' 2>/dev/null)"
      item "image" "$("${docker_cmd[@]}" inspect "$app" --format '{{.Config.Image}}' 2>/dev/null)"
      item "image arch" "$("${docker_cmd[@]}" image inspect "$("${docker_cmd[@]}" inspect "$app" --format '{{.Config.Image}}' 2>/dev/null)" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null)"
      item "ports" "$("${docker_cmd[@]}" port "$app" 2>/dev/null | tr '\n' ' ')"
      mem_pid=$("${docker_cmd[@]}" inspect "$app" --format '{{.State.Pid}}' 2>/dev/null)
      if [[ "${mem_pid:-0}" -gt 0 ]]; then
        item "resident memory" "$(ps -o rss= --ppid "$mem_pid" -p "$mem_pid" 2>/dev/null | awk '{s+=$1} END {printf "%d MB", s/1024}')"
      fi
    else
      item "container" "NOT CREATED"
    fi
  fi

  port=$([[ "$app" == shed ]] && echo 3000 || echo 8080)
  if command -v curl >/dev/null 2>&1; then
    item "local health check" "HTTP $(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://localhost:$port/api/health" 2>/dev/null)"
  fi

  if ((${#docker_cmd[@]})) && [[ -n "$status" ]]; then
    printf '  recent problem lines (routine activity excluded):\n'
    # Only lines that describe a problem or a startup event. Routine logs name
    # every sensor, and sensors are named after animals — that is the keeper's
    # data, it is useless for debugging, and it should not travel.
    log_lines=$("${docker_cmd[@]}" logs --tail 400 "$app" 2>&1 \
      | grep -iE 'error|warn|fatal|critical|exception|traceback|refus|denied|permission|cannot|could not|unable|failed|not found|no such|address already|EADDR|bind|listen|OOM|killed|exit|panic|unhandled' \
      | tail -20 | redact | scrub_readings)
    if [[ -n "$log_lines" ]]; then
      printf '%s\n' "$log_lines" | sed 's/^/      /'
    else
      printf '      (none — no errors or warnings in the recent log)\n'
    fi
  fi
done

# ── Backups ──────────────────────────────────────────────────────────────────
# "Is the backup working?" should have an answer that does not involve reading
# journald. The scheduled job writes this after every run, failures included.
section "Backups"
backup_status="${ANIMAL_BACKUP_STATUS:-/srv/sd-backup/var/backups/animal-apps/status.json}"
if [[ -r "$backup_status" ]]; then
  item "status file" "$backup_status"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$backup_status" <<'PYSTATUS'
import json, sys, time, datetime
try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except Exception as exc:
    print(f"  could not read the status file: {exc}")
    raise SystemExit(0)
ran = data.get("ran_at", "")
age = ""
try:
    when = datetime.datetime.strptime(ran, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    hours = (datetime.datetime.now(datetime.timezone.utc) - when).total_seconds() / 3600
    age = f" ({hours:.0f}h ago)"
    if hours > 48:
        age += "  ** no successful run in over two days"
except Exception:
    pass
print(f"  {'last run':<22} {ran}{age}")
print(f"  {'succeeded':<22} {', '.join(data.get('succeeded') or []) or 'none'}")
failed = data.get("failed") or []
print(f"  {'failed':<22} {', '.join(failed) if failed else 'none'}")
free = data.get("free_kb")
if isinstance(free, int):
    print(f"  {'free on backup device':<22} {free // 1024} MB")
for app, info in (data.get("apps") or {}).items():
    print(f"  {app + ' latest':<22} {info.get('latest')} ({info.get('archives')} archives)")
PYSTATUS
  fi
else
  item "status file" "not found — the scheduled backup may never have run"
fi

# ── Reaching it ──────────────────────────────────────────────────────────────
section "Reaching the apps"
item "hostname" "$(hostname)"
# Private LAN addresses only. A public address is identifying, so it is skipped.
lan=$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap)/ {print $4}' | cut -d/ -f1 \
      | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | tr '\n' ' ')
item "LAN address(es)" "${lan:-none found (private ranges only)}"
if command -v ss >/dev/null 2>&1; then
  item "listening" "$(ss -ltn 2>/dev/null | awk '$4 ~ /:(3000|8080)$/ {print $4}' | tr '\n' ' ')"
fi
item "mDNS (.local)" "$(command -v avahi-daemon >/dev/null 2>&1 && echo 'avahi installed' || echo 'avahi NOT installed — use the IP address instead of hostname.local')"

cat <<'NOTE'

=== What to do with this ===
  Copy everything above and send it to whoever is helping.
  Re-read it first if you like — there are no secrets or records in it.
NOTE
