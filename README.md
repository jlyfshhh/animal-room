<p align="center">
  <b>🏠 The Animal Room installer</b><br>
  One command to set up <b>Bask</b>, <b>Shed</b>, and <b>Clarity</b> — the self-hosted animal-care family — on your Raspberry Pi.
</p>

<p align="center">
  <a href="#install"><img alt="One-line install" src="https://img.shields.io/badge/install-one%20command-success"></a>
  <img alt="Raspberry Pi" src="https://img.shields.io/badge/Raspberry%20Pi-64--bit-C51A4A?logo=raspberrypi&logoColor=white">
  <a href="https://ko-fi.com/jlyfshhh"><img alt="Ko-fi" src="https://img.shields.io/badge/Ko--fi-buy%20crickets-FF5E5B?logo=ko-fi&logoColor=white"></a>
</p>

---

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

## The animal-room family

This installer sets up any combination of three companion projects for keepers:

| | Project | What it watches |
|---|---|---|
| ☀️ | **[Bask](https://github.com/jlyfshhh/bask)** | The environment — live temperature & humidity on a wall display |
| 🐍 | **[Shed](https://github.com/jlyfshhh/shed)** | The care — feeding, weights, enclosure work, and history for terrestrial animals |
| 💧 | **[Clarity](https://github.com/jlyfshhh/clarity)** | The water — aquarium & pond tests, maintenance, and livestock |

They're separate self-hosted services on purpose — one app can never take down
another — but they share a design language, and each keeps its own portable data.
