#!/usr/bin/env bash
# Haven: removes what install.sh set up, on purpose and in the right order.
set -euo pipefail

install_root="${ANIMAL_ROOM_HOME:-$HOME}"
dry_run=false
purge=false
assume_yes=false
select_bask=false
select_shed=false
has_selection=false

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33mNote:\033[0m %s\n' "$1"; }
die() { printf '\n\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: uninstall.sh [--bask] [--shed] [--all] [--purge] [--yes]
                    [--install-root PATH] [--dry-run]

With no app flags, the uninstaller opens an interactive chooser.

Your animal records and climate history are KEPT by default. The apps stop
and their containers and images are removed, but the data directory stays
exactly where it is, so reinstalling later picks up where you left off.

  --purge   also delete the data directory. This erases your records
            permanently. A backup is written first and its path printed.
  --yes     skip the confirmation prompt (for scripts).

Docker itself is never removed. Other things on this machine may be using it.
USAGE
}

while (($#)); do
  case "$1" in
    --bask) select_bask=true; has_selection=true ;;
    --shed) select_shed=true; has_selection=true ;;
    --all|--haven)
      select_bask=true
      select_shed=true
      has_selection=true
      ;;
    --purge) purge=true ;;
    --yes|-y) assume_yes=true ;;
    --install-root)
      shift
      (($#)) || die "--install-root needs a path."
      install_root="$1"
      ;;
    --dry-run) dry_run=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

choose_apps() {
  [[ -r /dev/tty ]] || die "No interactive terminal. Use --bask, --shed, or --all."
  cat >/dev/tty <<'MENU'

  Haven uninstaller
  -----------------
  1) Bask       enclosure climate monitoring
  2) Shed       animal care, schedules, and records
  3) Both

  Choose 1, 2, or 3:
MENU
  local answer
  IFS= read -r answer </dev/tty
  answer="${answer//[[:space:]]/}"
  case "$answer" in
    1|bask|Bask) select_bask=true; has_selection=true ;;
    2|shed|Shed) select_shed=true; has_selection=true ;;
    3|both|Both|all|All) select_bask=true; select_shed=true; has_selection=true ;;
    *) die "Unrecognised choice: $answer" ;;
  esac
}

[[ "$has_selection" == true ]] || choose_apps

# Docker may only be reachable through sudo, exactly as the installer found it.
# Probe with `sudo -n` first: a bare `sudo docker info` prints its password
# prompt to the terminal with no explanation of what is asking or why, which
# looks like the uninstaller has hung. Ask for the password only after saying
# what it is for.
docker_cmd=()
if ! command -v docker >/dev/null 2>&1; then
  : # Docker was never installed, or is already gone. Nothing to stop.
elif docker info >/dev/null 2>&1; then
  docker_cmd=(docker)
elif command -v sudo >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    docker_cmd=(sudo docker)
  elif [[ -r /dev/tty ]]; then
    say "Stopping the containers needs administrator access."
    sudo docker info >/dev/null 2>&1 && docker_cmd=(sudo docker)
  fi
fi
if ((${#docker_cmd[@]} == 0)); then
  warn "Docker is not reachable, so containers and images cannot be removed here.
     The app directories below are still handled."
fi

run() {
  if [[ "$dry_run" == true ]]; then
    printf '  would run: %s\n' "$*"
  else
    "$@"
  fi
}

selected_apps=()
[[ "$select_bask" == true ]] && selected_apps+=(bask)
[[ "$select_shed" == true ]] && selected_apps+=(shed)

# Say plainly what is about to happen before anything is touched. --purge is
# irreversible, so it gets a stronger prompt than the default path.
say "About to remove: ${selected_apps[*]}"
for app in "${selected_apps[@]}"; do
  printf '  %-6s %s\n' "$app" "$install_root/$app"
done
if [[ "$purge" == true ]]; then
  printf '\n  Data:  DELETED (a backup is written first)\n'
else
  printf '\n  Data:  kept in place\n'
fi

if [[ "$assume_yes" != true && "$dry_run" != true ]]; then
  [[ -r /dev/tty ]] || die "No terminal to confirm at. Pass --yes if you are sure."
  if [[ "$purge" == true ]]; then
    printf '\nThis permanently erases your records. Type PURGE to continue: ' >/dev/tty
    IFS= read -r reply </dev/tty
    [[ "$reply" == "PURGE" ]] || die "Cancelled. Nothing was changed."
  else
    printf '\nContinue? [y/N] ' >/dev/tty
    IFS= read -r reply </dev/tty
    [[ "$reply" == [yY]* ]] || die "Cancelled. Nothing was changed."
  fi
fi

backup_app() {
  local app="$1" dir="$2"
  local stamp dest
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$install_root/${app}-backup-${stamp}.tar.gz"
  # The archive can contain .env, which holds access tokens and — for Bask —
  # third-party account credentials. tar obeys the umask, so set it first
  # rather than chmod'ing a file that was briefly world-readable.
  ( umask 077
    tar -C "$dir" -czf "$dest" data 2>/dev/null ) || {
      warn "Nothing at $dir/data to back up."
      return 0
    }
  printf '  backup: %s\n' "$dest"
}

for app in "${selected_apps[@]}"; do
  dir="$install_root/$app"
  say "Removing $app"

  if [[ ! -d "$dir" ]]; then
    warn "$dir does not exist — skipping."
    continue
  fi

  if ((${#docker_cmd[@]})); then
    if [[ -f "$dir/compose.yaml" || -f "$dir/docker-compose.yml" ]]; then
      # Ask this project which images it actually built before tearing it down.
      # Deriving the name instead (app-app) is a guess that can match an
      # unrelated image and delete it.
      app_images="$( (cd "$dir" && "${docker_cmd[@]}" compose images -q 2>/dev/null) | sort -u || true)"

      # Only drop volumes when the keeper asked for the data to go. Shed and
      # Bask bind-mount ./data today, which --volumes would not touch, but a
      # compose file that switched to a named volume would lose every record
      # here with no way back.
      if [[ "$purge" == true ]]; then
        run bash -c "cd '$dir' && ${docker_cmd[*]} compose down --remove-orphans --volumes"
      else
        run bash -c "cd '$dir' && ${docker_cmd[*]} compose down --remove-orphans"
      fi

      # Images are rebuilt on reinstall, so removing them is safe and is the
      # bulk of the reclaimed space on a small card.
      if [[ -n "$app_images" ]]; then
        while IFS= read -r image_id; do
          [[ -n "$image_id" ]] && run bash -c "${docker_cmd[*]} image rm -f '$image_id' >/dev/null 2>&1 || true"
        done <<<"$app_images"
      fi
    else
      # No compose file left; fall back to the container name install.sh uses.
      run bash -c "${docker_cmd[*]} rm -f '$app' >/dev/null 2>&1 || true"
    fi
  fi

  if [[ "$purge" == true ]]; then
    [[ "$dry_run" == true ]] || backup_app "$app" "$dir"
    run rm -rf "$dir"
  else
    # Keep data and settings; drop the checkout and build artefacts around them.
    for item in "$dir"/*; do
      case "$(basename "$item")" in
        data|backups) continue ;;
        *) run rm -rf "$item" ;;
      esac
    done
    for item in "$dir"/.[!.]*; do
      [[ -e "$item" ]] || continue
      case "$(basename "$item")" in
        .env) continue ;;
        *) run rm -rf "$item" ;;
      esac
    done
  fi
done

if ((${#docker_cmd[@]})); then
  say "Reclaiming space"
  run bash -c "${docker_cmd[*]} image prune -f >/dev/null 2>&1 || true"
  run bash -c "${docker_cmd[*]} builder prune -f >/dev/null 2>&1 || true"
fi

cat <<SUMMARY

Uninstall complete.

SUMMARY

if [[ "$purge" == true ]]; then
  cat <<'DONE'
Everything was removed, including the data directories. The backups printed
above are the only remaining copies — move them somewhere safe.
DONE
else
  printf 'Your records are still here:\n\n'
  for app in "${selected_apps[@]}"; do
    [[ -d "$install_root/$app/data" ]] && printf '  %-6s %s\n' "$app" "$install_root/$app/data"
  done
  cat <<'DONE'

Reinstall on this machine — or copy those folders to a new one and install
there — and the apps pick up exactly where they left off.

  curl -fsSL https://animalroom.app/install.sh | bash
DONE
fi

if ((${#docker_cmd[@]})); then
  cat <<'DOCKER'

Docker was left installed. If you added it only for this and want it gone:

  sudo apt-get purge -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
DOCKER
fi
