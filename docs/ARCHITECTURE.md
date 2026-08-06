# Architektura

## Přehled komponent

```
                          Internet / útočníci
                                  │
                                  │ tcp/2222 (SSH), tcp/2223 (Telnet)
                                  ▼
   ┌──────────────────────────────────────────────────────────────┐
   │                         Host (VM)                             │
   │                                                                │
   │   ┌─────────────┐  honeypot-egress    ┌───────────────────┐   │
   │   │   Cowrie    │◄────172.30.0.0/24───┤  (jediná síť s      │  │
   │   │  (emulace)  │                     │   cestou ven,       │  │
   │   └──────┬──────┘                     │   filtrovanou)      │  │
   │          │ internal (bez cesty ven)    └───────────────────┘  │
   │          ▼                                                    │
   │   ┌─────────────┐     ┌──────────┐     ┌──────────────────┐   │
   │   │  Promtail   │────▶│   Loki   │◄────│      Grafana      │   │
   │   └─────────────┘     └──────────┘     └─────────┬────────┘   │
   │                                                    │ mgmt-publish│
   │   ┌────────────────────┐   ┌────────────────┐     │ (port-publish,│
   │   │ session-generator   │──▶│ session-viewer  │◄────┘ bez cesty ven)│
   │   │ (.cast + index.html)│   │ (nginx+basicauth)│                    │
   │   └────────────────────┘   └────────┬─────────┘                    │
   │                                       │                             │
   └───────────────────────────────────────┼─────────────────────────────┘
                                            │ tcp/3000, tcp/8080
                                            ▼
                                   Tvůj admin prohlížeč
                                (jen z ADMIN_CIDR, viz SECURITY.md)
```

## Tři Docker sítě a proč

| Síť | Kdo na ní je | Účel |
|---|---|---|
| `honeypot-egress` | Cowrie (statická IP) | Jediná síť, kudy může jakýkoli kontejner iniciovat spojení ven -- a i to jen na 80/443 díky firewallu |
| `internal` (Docker `internal: true`) | Cowrie, Promtail, Loki, Grafana, session-generator | Docker sám garantuje, že tahle síť nemá route ven -- žádné firewall pravidlo navíc není potřeba |
| `mgmt-publish` | Grafana, session-viewer, session-generator | Existuje **jen** kvůli tomu, že Docker neumí publikovat porty pro kontejner připojený jen na `internal: true` síť. `scripts/firewall.sh` na ni nedává žádnou výjimku -- efektivně žádnou cestu ven nemá, jen ověřeno testem |

## Proč jedna VM, ne dvě

Historicky se doporučuje honeypot a logovací/monitoring vrstvu oddělovat
na dvě VM (kdyby útočník unikl z emulace, nemůže smazat důkazy o
vlastním průniku). Tenhle projekt volí kompromis jedné VM:

- Cowrie je **emulace** (`backend = shell`), útočník nikdy nedostane
  reálný shell hostitele -- riziko úniku je nízké.
- Síťová izolace (VLAN doporučeno, viz DEPLOYMENT.md) už brání pohybu
  do zbytku tvé sítě, což byl hlavní důvod pro oddělení.
- Zbytkové riziko: při velmi nepravděpodobném úniku z emulace bys
  mohl přijít o data z toho konkrétního incidentu. Pro domácí lab je
  to akceptovatelný trade-off za jednodušší provoz.

Pokud chceš přísnější model, klidně přesuň `loki`+`grafana` na
samostatný host a uprav `promtail-config.yml` (`clients.url`) na jeho IP
-- architektura to podporuje, jen to není výchozí nastavení.

## Proč Docker Compose, ne vlastní build

Cowrie, Loki, Grafana a nginx jsou aktivně vyvíjené a udržované
upstream projekty -- rebuildovat je vlastními Dockerfily by znamenalo
ztrátu automatických bezpečnostních aktualizací a zbytečnou údržbu.
Vlastní `Dockerfile` má jen to, co jsme postavili sami:

- `docker/session-generator/` -- malý Python image, co periodicky
  převádí zachycené relace na webově přehratelný formát
- `docker/fakefs-builder/` -- jednorázový zdrojový obraz pro
  `scripts/build-fakefs.sh`, nikdy neběží jako služba

## Datový tok

1. Útočník se připojí na Cowrie (2222/2223)
2. Cowrie zapisuje JSON log (`cowrie.json`) + TTY záznam relace (ttylog) do Docker volumes
3. Promtail sleduje `cowrie.json`, pushuje do Loki
4. Grafana dotazuje Loki přes LogQL -- dashboard je hotový hned po startu (provisioning)
5. `session-generator` periodicky projde `cowrie.json`, najde uzavřené relace, převede ttylog na asciinema `.cast`, vygeneruje `webui/index.html`
6. `session-viewer` (nginx) servíruje `webui/` s basic-auth ochranou
