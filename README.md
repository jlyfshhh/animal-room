# Animal Room installer

One installer for the **Bask**, **Shed**, and **Clarity** self-hosted animal-care
apps. It is designed for a 64-bit Raspberry Pi running Raspberry Pi OS, but also
works on 64-bit Debian systems.

## Install

On the Pi, run:

```bash
curl -fsSL https://raw.githubusercontent.com/jlyfshhh/animal-room/main/install.sh | bash
```

The installer asks which apps you want:

- **Bask** — enclosure temperature and humidity sensor monitoring
- **Shed** — terrestrial animal husbandry schedules and records
- **Clarity** — aquarium and pond maintenance
- **All three**

It installs Docker from Docker's official Debian repository when needed, then
uses each app's own installer. Re-running the command updates code and
containers without replacing settings or databases.

For an unattended install:

```bash
curl -fsSL https://raw.githubusercontent.com/jlyfshhh/animal-room/main/install.sh |
  bash -s -- --all
```

You can also use `--bask`, `--shed`, or `--clarity` in any combination.

## Default addresses and storage

| App | Address | Code | Persistent data |
|---|---|---|---|
| Bask | `http://HOSTNAME.local:8080` | `~/bask` | `~/bask/data` |
| Shed | `http://HOSTNAME.local:3000` | `~/shed` | `~/shed/data` |
| Clarity | `http://HOSTNAME.local:3001` | `~/clarity` | `~/clarity/data` |

Set `ANIMAL_ROOM_HOME` or pass `--install-root PATH` to choose a different
parent directory.

## Existing Bask installs

When Bask detects its former systemd/virtualenv installation, it:

1. stops and disables the old Bask services;
2. creates a timestamped pre-migration backup;
3. snapshots the SQLite database safely, including any WAL data;
4. copies settings and history into `~/bask/data`; and
5. starts the Docker version.

The original files remain available until you choose to remove them.

## Data ownership

The installer does not merge the apps' databases or put data in a cloud
service. Each app keeps ordinary files in its own `data` directory so they can
be backed up, moved to another computer, or imported into a future version.

Do not expose ports 8080, 3000, or 3001 directly to the public internet.
