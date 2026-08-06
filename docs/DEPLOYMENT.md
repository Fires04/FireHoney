# Nasazení -- krok za krokem

## 0. Předpoklady

- Čerstvá Linux VM (testováno na Debian 13), ideálně samostatná
  (Proxmox nebo jiný hypervizor), na izolované síti/VLAN
- Uživatel se sudo právy
- ~2 GB RAM, 20 GB disk

Doporučená síťová izolace (Proxmox + Ubiquiti jako příklad, princip
platí obecně): honeypot VM na vlastní VLAN, pravidla:

| Zdroj | Cíl | Akce |
|---|---|---|
| Honeypot VLAN | zbytek LAN | **Block** |
| Honeypot VLAN | management rozhraní routeru/switche | **Block** |
| Tvoje admin IP | Honeypot VLAN, porty 22/3000/8080 | **Allow** |
| Internet (WAN) | Honeypot VLAN, porty 2222/2223 | **Allow** (port forward) |
| Internet (WAN) | cokoliv jiného | **Block** (default) |

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
sudo usermod -aG docker "$USER"   # odhlas se a znovu prihlas
```

## 2. Stažení a konfigurace projektu

```bash
git clone <tento-repo> cowrie-honeypot-stack
cd cowrie-honeypot-stack
cp .env.example .env
$EDITOR .env
```

V `.env` uprav minimálně:
- `GRAFANA_ADMIN_PASSWORD`, `VIEWER_PASSWORD` -- vlastní hesla
- `WAN_IFACE` -- zjisti přes `ip route | grep default`
- `ADMIN_CIDR` -- IP/rozsah, odkud smíš na správu (SSH, Grafana, viewer)

Podrobný popis všech proměnných: [CONFIGURATION.md](CONFIGURATION.md)

## 3. Setup a spuštění

```bash
make setup       # htpasswd, asciinema-player, docker pull
make fakefs       # (doporučeno) realistický fake filesystem -- viz ANTI-DETECTION.md
make up           # rozjede cely stack
sudo make firewall
```

Ověř, že vše běží:
```bash
docker compose ps    # 6 kontejnerů: cowrie, promtail, loki, grafana,
                      # session-viewer, session-generator -- vsechny "Up"
```

## 4. Ověření

```bash
# reálný test login (potřebuješ sshpass: sudo apt install sshpass)
sshpass -p test123 ssh -o StrictHostKeyChecking=no attacker@localhost -p "${COWRIE_SSH_PORT:-2222}" "whoami; uname -a; exit"
```

- Grafana: `http://SERVER_IP:3000` (login z `.env`) -- rovnou uvidíš
  hotový dashboard
- Session viewer: `http://SERVER_IP:8080` (basic-auth z `.env`) --
  po chvíli (`SESSION_GENERATOR_INTERVAL`) se objeví tvůj test login,
  nebo hned: `make sessions` (spustí generátor na počkání, bez čekání
  na další tik smyčky)

## 5. Firewall ověření

```bash
docker exec cowrie /cowrie/cowrie-env/bin/python3 -c \
  "import socket; socket.create_connection(('1.1.1.1',443),timeout=5); print('OK 443')"
# mělo by projít -- to je jediná povolená výjimka

docker exec session-viewer wget -T3 -O- http://1.1.1.1
# mělo by SPADNOUT na timeout
```

## 6. Port forward na routeru

Až budeš připraven vystavit do internetu:
- `WAN:22 → SERVER_IP:${COWRIE_SSH_PORT}` (vypadá jako běžný SSH port zvenku)
- `WAN:23 → SERVER_IP:${COWRIE_TELNET_PORT}`
- **Neforwarduj** porty 3000/8080/skutečný SSH admin port -- ty musí
  zůstat dostupné jen z `ADMIN_CIDR`.

## 7. Snapshot / golden state

Než na to pustíš skutečné útočníky, udělej snapshot VM (Proxmox/hypervizor)
v tomhle čistém stavu -- viz [SECURITY.md](SECURITY.md) pro doporučenou
periodickou obnovu.

## Aktualizace

```bash
git pull
make update        # docker compose pull + up -d
sudo make firewall  # znovu, aby pravidla sedela na aktualní síť
```

## Odinstalace

```bash
docker compose down -v   # -v smaže i data (logy, session, Grafana state)
sudo iptables -F DOCKER-USER
```
