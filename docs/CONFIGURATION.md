# Konfigurace

## `.env` -- infrastrukturní nastavení

| Proměnná | Výchozí | Co dělá |
|---|---|---|
| `COWRIE_SSH_PORT` | 2222 | Port na hostu pro Cowrie SSH |
| `COWRIE_TELNET_PORT` | 2223 | Port na hostu pro Cowrie Telnet |
| `GRAFANA_PORT` | 3000 | Port na hostu pro Grafana web UI |
| `SESSION_VIEWER_PORT` | 8080 | Port na hostu pro přehled relací |
| `GRAFANA_ADMIN_USER` | admin | Grafana admin login |
| `GRAFANA_ADMIN_PASSWORD` | — | **Změň!** Grafana admin heslo |
| `VIEWER_USER` | viewer | Basic-auth login pro session-viewer |
| `VIEWER_PASSWORD` | — | **Změň!** Basic-auth heslo, generuje se do `config/nginx/htpasswd` skriptem `make setup` |
| `WAN_IFACE` | eth0 | Síťové rozhraní hostu -- zjisti `ip route \| grep default` |
| `ADMIN_CIDR` | — | Odkud smíš na SSH/Grafanu/viewer. Nikdy `0.0.0.0/0` |
| `DNS_RESOLVERS` | 1.1.1.1,9.9.9.9 | Jediné DNS servery, na které Cowrie smí (pro resolvnutí URL při stahování vzorků) |
| `COWRIE_EGRESS_SUBNET` | 172.30.0.0/24 | Interní Docker podsíť Cowrie -- měnit jen při konfliktu |
| `COWRIE_IP` | 172.30.0.10 | Statická IP Cowrie na této podsíti (firewall na ni cílí přesně) |
| `MGMT_PUBLISH_SUBNET` | 172.31.0.0/24 | Interní podsíť pro Grafana/viewer/generator |
| `LOKI_RETENTION_HOURS` | 2160 (90 dní) | Jak dlouho Loki drží logy |
| `SESSION_GENERATOR_INTERVAL` | 120 | Jak často (s) hledat nové zachycené relace |

Po každé změně `.env`: `docker compose up -d` (znovu vytvoří jen
kontejnery, které to potřebují) a pokud jsi měnil síťové/porty
proměnné, znovu spusť `sudo make firewall`.

## `config/cowrie/cowrie.cfg` -- chování honeypotu

Malý soubor, jen naše overrides nad Cowrie vestavěnými defaults (Cowrie
si `cowrie.cfg.dist` načte sám interně z balíčku). Klíčové volby:

- `hostname` -- jak se honeypot jmenuje (`uname -a`, prompt). Pokud
  ho měníš, sjednoť i s `docker/fakefs-builder/Dockerfile` (tam je
  hardcoded `webprod03` v `/etc/hostname`).
- `backend = shell` -- **nikdy neměň** na `proxy`/`llm`. Emulace je
  bezpečnostní hranice celého projektu.
- `filesystem = etc/fs.pickle` -- viz `make fakefs` a
  [ANTI-DETECTION.md](ANTI-DETECTION.md)
- `download_limit_size` -- limit velikosti stahovaných vzorků malwaru

**Soubor musí zůstat čistě ASCII** (i komentáře) -- Cowrie ho čte
striktně jako ASCII, jinak spadne načítání a *všechna* přihlášení
začnou selhávat.

Po úpravě: `docker compose restart cowrie` (nebo `make reset-cowrie`).

## `config/cowrie/userdb.txt` -- kdo se může přihlásit

Zpracovává se řádek po řádku, **první shoda vyhrává**:
- `username:x:*` -- povolí libovolné heslo
- `username:x:!heslo` -- zakáže konkrétní heslo
- `username:x:!/regex/` -- zakáže cokoliv, co matchuje regex
  (`!/.*/ ` = zakáže úplně vše pro toho uživatele)

Výchozí soubor je třívrstvý (viz komentáře uvnitř):
1. Systémové účty (`www-data`, `mysql`...) -- zamítnuty úplně
2. Pár "je-tohle-honeypot" canary hesel pro root -- zamítnuta
3. Všechno ostatní -- povoleno (hlavní zdroj dat)

Chceš vidět víc "neúspěšných" přihlášení v Grafaně? Přidej víc
explicitních `!heslo` řádků -- ale pozor, snižuješ tím objem
zachycených dat od běžných botů. Viz diskuze v
[ANTI-DETECTION.md](ANTI-DETECTION.md).

**I tenhle soubor musí být čistě ASCII.**

## `config/promtail/promtail-config.yml` -- volitelný GeoIP

Zdarma s registrací na [maxmind.com](https://www.maxmind.com/) stáhni
`GeoLite2-City.mmdb`, ulož do `config/promtail/GeoLite2-City.mmdb`,
odkomentuj `geoip` stage v souboru, `docker compose restart promtail`.
Funguje čistě lokálně, žádné odchozí dotazy navíc.

## `config/grafana/provisioning/dashboards/cowrie-overview.json`

Dashboard se nahrává automaticky při startu Grafany (file-based
provisioning). Uprav JSON přímo, nebo uprav v Grafana UI a exportuj
zpět (Dashboard settings → JSON Model) -- jen pozor na
`"datasource": {"uid": "loki"}` referenci, musí zůstat `loki` (matchuje
`config/grafana/provisioning/datasources/loki.yaml`).

## `config/nginx/session-viewer.conf`

Basic-auth + statické servírování `webui/`. Pro víc uživatelů přidej
řádky do `config/nginx/htpasswd` (`htpasswd -B config/nginx/htpasswd novy_user`).
