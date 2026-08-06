# Cowrie Honeypot Stack

Kompletní, znovupoužitelný Docker Compose balíček pro nasazení SSH/Telnet
honeypotu ([Cowrie](https://github.com/cowrie/cowrie)) s živým monitoringem
a webovým přehráváním zachycených relací -- postavené jako moderní
náhrada za nevyvíjený [HoneyDrive](https://sourceforge.net/projects/honeydrive/).

![status](https://img.shields.io/badge/status-home--lab-orange)

## Co dostaneš

- **Cowrie** -- emulovaný SSH/Telnet honeypot (útočník nikdy nedostane
  skutečný shell, jen věrohodnou napodobeninu)
- **Grafana dashboard** -- hotový při prvním startu (auto-provisioning),
  živé grafy přihlašovacích pokusů, top hesel, streamu příkazů
- **Webové přehrávání relací** -- self-hosted (asciinema-player), žádné
  CDN, žádný SSH ani terminál potřeba
- **Realistický fake filesystem** -- generovaný z opravdového Debian
  serveru s balíčky (ne generický default, co má každá Cowrie instalace
  na světě stejný)
- **Přísný egress firewall** -- kontejner honeypotu nesmí ven nikam
  kromě přesně definované výjimky (stahování malware vzorků)
- Vše ovladatelné jedním `.env` souborem

## Rychlý start

```bash
git clone <tento-repo> cowrie-honeypot-stack
cd cowrie-honeypot-stack
cp .env.example .env
$EDITOR .env              # nastav hesla, WAN_IFACE, ADMIN_CIDR

make setup                # htpasswd, asciinema-player, docker pull
make fakefs                # (doporučeno) realistický fake filesystem
make up                    # rozjede celý stack
sudo make firewall         # egress lockdown

# Grafana:         http://SERVER_IP:3000
# Session viewer:  http://SERVER_IP:8080
```

**Než to vystavíš do internetu**, projdi si [docs/SECURITY.md](docs/SECURITY.md)
checklist -- síťová izolace (VLAN), port forwarding, a co dělat, než na
to pustíš reálné útočníky.

## Dokumentace

| Dokument | O čem je |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Jak to je poskládané, síťový diagram, proč jedna VM |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Krok za krokem od čerstvé VM po běžící honeypot |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Co dělá každá `.env` proměnná, jak upravit `cowrie.cfg`/`userdb.txt` |
| [docs/SECURITY.md](docs/SECURITY.md) | Firewall model, checklist před vystavením do světa, GDPR |
| [docs/ANTI-DETECTION.md](docs/ANTI-DETECTION.md) | Proč a jak honeypot vypadá méně nápadně |

## Požadavky

- Linux server (testováno na Debian 13), Docker Engine + Compose plugin
- Doporučeno: samostatná VM (Proxmox nebo jiný hypervizor), izolovaná
  síť/VLAN -- viz [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- ~2 GB RAM, 20 GB disk

## Struktura projektu

```
.
├── docker-compose.yml       # orchestrace, čte .env
├── .env.example              # zkopíruj na .env a uprav
├── Makefile                  # make setup/up/down/firewall/fakefs/...
├── config/
│   ├── cowrie/                cowrie.cfg, userdb.txt, fs.pickle (generovaný)
│   ├── promtail/               promtail-config.yml
│   ├── loki/                   loki-config.yml
│   ├── nginx/                  session-viewer.conf, htpasswd (generovaný)
│   └── grafana/provisioning/   datasource + dashboard, nahraje se sám
├── docker/
│   ├── session-generator/     vlastní image: převádí relace na .cast + index.html
│   └── fakefs-builder/         vlastní image: zdroj pro realistický filesystem
├── scripts/
│   ├── setup.sh                jednorázová příprava
│   ├── build-fakefs.sh          generuje fs.pickle
│   └── firewall.sh              egress lockdown
├── webui/                     player.html + generovaný obsah
└── docs/                       viz tabulka výše
```

## Proč tahle architektura

Cowrie je emulace (útočník nikdy nedostane reálný shell), takže je to
podstatně bezpečnější než honeypot s reálným OS. I tak je nasazení
navržené s vrstvenou obranou: izolovaná síť (doporučeno), striktní
odchozí firewall na úrovni Dockeru, žádná admin rozhraní vystavená do
internetu. Detaily v [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) a
[docs/SECURITY.md](docs/SECURITY.md).

## Licence

MIT (viz LICENSE). Cowrie samo má vlastní licenci (BSD-3-Clause).
