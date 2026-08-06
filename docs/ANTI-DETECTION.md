# Anti-detection

Cowrie (like most SSH honeypots) has a handful of recognizable
fingerprints. This document summarizes what gives us away, what we've
done about it, and why we don't chase this indefinitely.

## The reality of the traffic

The vast majority of traffic that hits a public IP on port 22/23 is
**automated bots and scanners** (Mirai variants, credential-stuffing
scripts). They don't care about honeypot detection at all -- they
just mechanically try creds and run canned commands. That's exactly
what you want to study, and Cowrie handles it fine out of the box.
Targeted honeypot detection mainly matters against a sophisticated
human attacker or a red teamer.

## What gives us away

1. **Permissive `userdb.txt`** -- an attacker tries a nonsense
   password, a real server would reject it. The biggest tell, but
   also the biggest source of data.
2. **The emulated shell has gaps** -- Cowrie doesn't emulate coreutils
   perfectly (e.g. `head -3`/`tail -3` with the numeric shorthand
   fails). Not easily fixable without patching Cowrie itself.
3. **Generic fake filesystem** -- the default `fs.pickle` is identical
   across every Cowrie install on earth.
4. **SSH `kex`/`hassh` fingerprint** -- public tools exist (including
   Shodan Honeyscore) that actively test for it.
5. **Behavior under load** -- a real server slows down under
   brute-force, Cowrie accepts connections instantly and endlessly.

## What's actually fine

- The TCP/IP stack is **real** (runs on an actual Debian kernel inside
  a Docker container) -- low-level fingerprints (p0f) check out
- The SSH banner matches the kernel (`OpenSSH_9.2p1 Debian-12` +
  `uname` reporting a Debian 12 kernel) -- internally consistent

## What this project does about it

### 1. Realistic fake filesystem (`make fakefs`)

`scripts/build-fakefs.sh` builds a one-shot `debian:12-slim` container
with typical packages installed (nginx, php, mariadb-client...) and a
bit of realistic "clutter" (`/var/www/html`, `/opt/app/.env`), exports
its filesystem, and uses Cowrie's own `createfs` tool to turn it into
`config/cowrie/fs.pickle`.

**Security note:** `createfs` embeds real file CONTENT only for a
handful of fixed paths (`/etc/passwd`, `/etc/shadow`, `/etc/hostname`,
`/etc/os-release`, `/proc/cpuinfo`...). **Never run
`build-fakefs.sh` against a production/real host** -- the source must
always be that disposable, unrelated container from
`docker/fakefs-builder/`. If it were run against a real machine, the
actual `/etc/shadow` with your admin account's hash would end up
readable by attackers inside the honeypot.

Two subtle issues we hit while generating this, both handled by
`build-fakefs.sh`:
- `docker export` doesn't carry over `/etc/hostname` content (Docker
  manages it outside the image layer) -- the script writes it back
  manually after export.
- `/etc/os-release` is a symlink to `/usr/lib/os-release` on a real
  Debian system; `createfs` only embeds content for regular files,
  not symlinks -- the script dereferences it before generating.

### 2. Layered `userdb.txt`

System/service accounts (`www-data`, `mysql`, `nobody`...) are denied
outright -- a real server sets their shell to `/usr/sbin/nologin`, so
an interactive login wouldn't succeed anyway. Root additionally has
four common "is this a honeypot?" canary combos denied
(`root/root`, `root/123456`, anything containing "honeypot" or
"cowrie"). Everything else stays permissive -- that's intentional,
it's the main source of data.

**A trap we hit:** Cowrie reads `userdb.txt` strictly as ASCII.
Non-English comments (accented characters) in the file cause a
`UnicodeDecodeError` on load, which breaks **every single** login
(fail-closed), not just the intentionally denied ones -- it looks
like "everything is suddenly broken" rather than an obvious config
mistake. Keep `userdb.txt` and `cowrie.cfg` pure ASCII.

## What we haven't tackled (yet)

- Timing/protocol fingerprints at the Twisted async stack level
  (research exists, but it's a deeper rabbit hole than makes sense
  for a home lab)
- Exact package database matching (`dpkg -l` output) against a real
  system -- the fake filesystem has structure, not a functioning
  `dpkg`
- Threat-intel sharing (SANS DShield) -- see the commented-out
  `[output_dshield]` section in `cowrie.cfg`, requires its own
  additional firewall exception
