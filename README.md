<p align="center">
  <b>🌿 Animal Room</b><br>
  The project site at <b>animalroom.app</b>, and <b>Haven</b> — one installer for
  <b>Bask</b>, <b>Shed</b>, or their combined room dashboard.
</p>

<p align="center">
  <a href="#install"><img alt="One-line install" src="https://img.shields.io/badge/install-one%20command-success"></a>
  <a href="https://animalroom.app/haven/"><img alt="Haven website" src="https://img.shields.io/badge/website-meet%20Haven-3f755a"></a>
  <img alt="Raspberry Pi" src="https://img.shields.io/badge/Raspberry%20Pi-64--bit-C51A4A?logo=raspberrypi&logoColor=white">
  <a href="https://ko-fi.com/jlyfshhh"><img alt="Ko-fi" src="https://img.shields.io/badge/Ko--fi-buy%20crickets-FF5E5B?logo=ko-fi&logoColor=white"></a>
</p>

---

**Bask watches the habitat. Shed organizes the care. Haven brings both into
one calm room dashboard.**

Haven is not another database or another app to maintain. It is the combined
installation and read-only wall display you get when Bask and Shed run
together. Each app stays independent, and each keeps its own portable data.

**[Meet Haven on the project website →](https://animalroom.app/haven/)**

## Which should I choose?

| Choice | Best when you want |
|---|---|
| **Bask** | Live enclosure temperature and humidity monitoring from compatible Bluetooth sensors |
| **Shed** | Shared care schedules, household task attribution, weights, feeding, equipment, notes, and history |
| **Haven** *(recommended)* | Everything in Bask and Shed, plus one wall dashboard showing enclosure status and today's remaining care |

You can start with either app and run the installer again later to add the
other one and enable Haven. No data is replaced.

## What you need

| | Bask alone | Shed alone | Haven (both) |
|---|---|---|---|
| Memory | 512 MB | **1 GB** | 2 GB |
| Comfortable on | Pi Zero 2 W, Pi 3 | Pi 3 (1 GB+), Pi 4 | Pi 4, Pi 5 |

Both need a 64-bit OS and a few GB of free disk.

Nothing is compiled during installation. Both apps are published as prebuilt
multi-architecture images, so installing downloads a container and starts it —
your board only ever has to *run* the apps, not build them. Measured while
running: Bask about 130 MB, Shed about 300 MB.

Measured on arm64, Shed's worker peaks near **390 MB** while starting. A Pi
Zero 2 W has 512 MB in total, so once the OS has taken its share there is not
enough left — and if the board is already doing another job, less still. Shed
gets killed part way through starting, which looks exactly like a successful
install whose address then refuses to load. **A Pi Zero 2 W is a Bask board.**
Give Shed 1 GB, and the pair 2 GB.

You can also start with one app and add the other later; the installer will not
disturb what is already there.

## Install

On a 64-bit Raspberry Pi running Raspberry Pi OS, or another 64-bit Debian
system, run:

```bash
curl -fsSL https://animalroom.app/install.sh | bash
```

Choose **Bask**, **Shed**, or **Haven**. The installer adds Docker from Docker's
official Debian repository when needed, installs the selected app or apps, and
automatically makes the secure server-to-server connection required by Haven.

For an unattended Haven install:

```bash
curl -fsSL https://animalroom.app/install.sh | bash -s -- --haven
```

`--bask`, `--shed`, and `--all` are also accepted. `--all` is an alias for
Haven. Re-running the command updates the selected apps without replacing data.

## Addresses and storage

The installer finishes by printing the address for each app it set up. Use the
**numeric** one — `http://192.168.1.50:3000`, with your board's own address.
It works from every phone and computer on the network.

| Surface | Address | Persistent data |
|---|---|---|
| Bask | `http://LAN-ADDRESS:8080` | `~/bask/data` |
| Shed | `http://LAN-ADDRESS:3000` | `~/shed/data` |
| Haven room display | `http://LAN-ADDRESS:8080/room.html` | Reads Bask and Shed; stores no separate copy |

The installer also offers `http://HOSTNAME.local:PORT` as an alternative. It is
easier to remember, but it needs mDNS, which Windows without Bonjour and a good
many Android phones do not do — there the address simply refuses to load, with
nothing on screen to say why. Treat it as a convenience, not the way in.

Set `ANIMAL_ROOM_HOME` or pass `--install-root PATH` to choose a different
parent directory.

## What Haven shares

Haven gives Bask read-only access to a deliberately limited Shed display feed.
That feed includes today's incomplete and overdue care plus anonymous totals.
It excludes household identities, rewards, access codes, history, completion
IDs, and all write access. A separate random display secret is generated during
installation and stays in the apps' private `.env` files; it is never sent to
the browser.

Because Bask and Shed remain separate services, either app can still be used on
its own. The room display clearly reports when one side is unavailable instead
of hiding the failure.

## Existing Bask or Shed installs

Run the Haven installer with the same install root. Existing databases,
settings, and backups remain in place. Bask also safely migrates its former
systemd/virtualenv installation when it detects one, including a timestamped
pre-migration SQLite snapshot.

Before installing Shed, the unified installer checks that the host has its
1&nbsp;GB minimum; Bask remains available by itself on a 512&nbsp;MB board. After
an install or update it waits for each selected app's health endpoint, and a
Haven install additionally verifies that Bask can read Shed's display feed. If
startup, memory, or that connection check fails, the installer restores the
previous Compose settings and running image while leaving every `data` and
`backups` directory alone.

## Something not working?

```bash
curl -fsSL https://animalroom.app/doctor.sh | bash
```

Prints a report of what is installed, what is running, how much memory the board
has, whether a container was killed, and any recent error lines — then you can
paste the whole thing to whoever is helping.

It reads state only and changes nothing. It does **not** collect your settings
file, any access code or token, your animals' records, your database, or your
public IP address: secret settings are listed by name with "set" or "empty"
instead of a value, routine log lines are dropped, and anything token-shaped or
reading-shaped is filtered out. Read it before you send it if you like.

## Uninstalling

```bash
curl -fsSL https://animalroom.app/uninstall.sh | bash
```

Choose Bask, Shed, or both. **Your records are kept by default.** The apps stop
and their containers and images are removed, but the `data` directory and your
settings stay exactly where they are, so reinstalling later — here or on a
different machine — picks up where you left off.

```bash
curl -fsSL https://animalroom.app/uninstall.sh | bash -s -- --shed
```

`--bask`, `--shed`, and `--all` skip the chooser. `--install-root PATH` matches
the installer.

To remove one app and keep the other — for example dropping Shed from a board
that does not have the memory to run it, while Bask keeps running — uninstall
just that one.

To erase the records too, add `--purge`. It writes a timestamped backup archive
first and prints the path, then asks you to type `PURGE` to confirm.

Docker is never removed automatically; other things on the machine may be using
it. The uninstaller prints the commands if you want it gone.

## Data ownership and safety

- Bask and Shed keep ordinary files in separate `data` directories.
- Both projects include backup tools; Shed also exports portable JSON and CSV.
- The installer does not merge databases or upload animal data to a cloud.
- Do not expose ports 8080 or 3000 directly to the public internet.

## Projects

| | Project | Purpose |
|---|---|---|
| ☀️ | **[Bask](https://github.com/jlyfshhh/bask)** | The environment — live enclosure temperature and humidity |
| 🐍 | **[Shed](https://github.com/jlyfshhh/shed)** | The care — schedules, records, weights, feeding, and shared household work |
| 🌿 | **Haven** *(built here)* | The bridge — one installer and one room view for Bask + Shed |

This repository also holds the site served at **animalroom.app**. The landing
pages for Shed and Bask live in `site/shed/` and `site/bask/` here — not in
their own repositories, which keep only a redirect.

## Versions and license

There is nothing to version here in the usual sense: `install.sh`,
`uninstall.sh`, `doctor.sh`, and the site are published from `main` by the Pages
workflow, so the copy you download is always the current one. Re-running the
installer is how you update. Bask and Shed each carry their own version, set in
their own repositories, and `doctor.sh` prints which images are actually
installed.

Everything in this repository is MIT licensed — see [LICENSE](LICENSE). Bask and
Shed are MIT licensed in their own repositories, which is the license the site
refers to on each page.
