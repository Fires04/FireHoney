# Deployment -- step by step

## 0. Prerequisites

- A fresh Linux VM (tested on Debian 13), ideally dedicated (Proxmox
  or any other hypervisor), on an isolated network/VLAN
- A user with sudo rights
- ~2 GB RAM, 20 GB disk

Recommended network isolation (Proxmox + Ubiquiti as an example, the
principle applies generally): honeypot VM on its own VLAN, rules:

| Source | Destination | Action |
|---|---|---|
| Honeypot VLAN | rest of LAN | **Block** |
| Honeypot VLAN | router/switch management interface | **Block** |
| Your admin IP | Honeypot VLAN, ports 22/3000/8080 | **Allow** |
| Internet (WAN) | Honeypot VLAN, ports 2222/2223 | **Allow** (port forward) |
| Internet (WAN) | anything else | **Block** (default) |

## 1. Docker

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"   # log out and back in
```

## 2. Download and configure the project

```bash
git clone https://github.com/Fires04/FireHoney.git cowrie-honeypot-stack
cd cowrie-honeypot-stack
cp .env.example .env
$EDITOR .env
```

At minimum, set in `.env`:
- `GRAFANA_ADMIN_PASSWORD`, `VIEWER_PASSWORD` -- your own passwords
- `WAN_IFACE` -- find it with `ip route | grep default`
- `ADMIN_CIDR` -- the IP/range you're allowed to administer from (SSH, Grafana, viewer)

Full description of every variable: [CONFIGURATION.md](CONFIGURATION.md)

## 3. Setup and startup

```bash
make setup       # htpasswd, asciinema-player, docker pull
make fakefs        # (recommended) realistic fake filesystem -- see ANTI-DETECTION.md
make up             # bring up the whole stack
sudo make firewall
```

Verify everything is running:
```bash
docker compose ps    # 6 containers: cowrie, promtail, loki, grafana,
                      # session-viewer, session-generator -- all "Up"
```

## 4. Verification

```bash
# a real test login (needs sshpass: sudo apt install sshpass)
sshpass -p test123 ssh -o StrictHostKeyChecking=no attacker@localhost -p "${COWRIE_SSH_PORT:-2222}" "whoami; uname -a; exit"
```

- Grafana: `http://SERVER_IP:3000` (login from `.env`) -- you'll land
  straight on the ready-made dashboard
- Session viewer: `http://SERVER_IP:8080` (basic-auth from `.env`) --
  your test login shows up after a bit (`SESSION_GENERATOR_INTERVAL`),
  or right away: `make sessions` (runs the generator on demand,
  without waiting for the next loop tick)

## 5. Firewall verification

```bash
docker exec cowrie /cowrie/cowrie-env/bin/python3 -c \
  "import socket; socket.create_connection(('1.1.1.1',443),timeout=5); print('OK 443')"
# should succeed -- that's the one allowed exception

docker exec session-viewer wget -T3 -O- http://1.1.1.1
# should time out
```

## 6. Port forwarding on your router

Once you're ready to expose this to the internet:
- `WAN:22 → SERVER_IP:${COWRIE_SSH_PORT}` (looks like a regular SSH port from outside)
- `WAN:23 → SERVER_IP:${COWRIE_TELNET_PORT}`
- **Do not forward** ports 3000/8080/the real SSH admin port -- those
  must stay reachable only from `ADMIN_CIDR`.

## 7. Snapshot / golden state

Before you let real attackers at it, take a VM snapshot
(Proxmox/hypervisor) in this clean state -- see
[SECURITY.md](SECURITY.md) for the recommended periodic reset.

## Updating

```bash
git pull
make update        # docker compose pull + up -d
sudo make firewall  # again, so the rules match the current network
```

## Uninstalling

```bash
docker compose down -v   # -v also deletes data (logs, sessions, Grafana state)
sudo iptables -F DOCKER-USER
```
