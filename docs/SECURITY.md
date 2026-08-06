# Bezpečnost

## Model odchozího provozu (egress)

Výchozí politika: **žádné kontejnerem iniciované odchozí spojení není
povolené**. Jediná výjimka: Cowrie kontejner smí nové spojení na
tcp/80,443 (rate-limited, logované) -- protože na povel útočníka
(`wget`/`curl` ve fake shellu) potřebuje umět stáhnout a uložit
skutečný malware vzorek k analýze. Cowrie soubor jen stáhne, **nikdy
ho nespustí**.

Implementováno v `scripts/firewall.sh` v řetězci `DOCKER-USER`
(Docker tenhle řetězec nikdy nepřepíše, je určený přesně pro vlastní
pravidla nad kontejnerovým provozem). Vše ostatní -- Loki, Grafana,
Promtail, session-viewer, session-generator -- nemá do internetu
žádnou cestu vůbec (buď Docker `internal: true` síť, nebo explicitní
firewall pravidlo bez výjimky).

Tripwire: jakýkoli pokus o odchozí spojení mimo povolený rámec se
zaloguje jako `HONEYPOT-EGRESS-BLOCKED` / `MGMT-EGRESS-BLOCKED`
(`journalctl -k`). Sleduj to -- výskyt = podezření na únik z emulace
nebo chyba v konfiguraci.

## Přístup dovnitř (ingress)

- Cowrie porty (2222/2223 → zvenku obvykle 22/23) -- veřejné, to je
  cílem
- Grafana (3000) a session-viewer (8080) -- **nikdy nevystavuj do
  internetu**. Firewall na úrovni sítě/routeru musí povolovat přístup
  jen z `ADMIN_CIDR`. Aplikace samy mají navíc login (Grafana) /
  basic-auth (viewer), ale to není náhrada za síťové omezení.
- Skutečný SSH pro správu VM -- taky jen z `ADMIN_CIDR`, nikdy z WAN.

## Checklist před vystavením do internetu

- [ ] VM je samostatná, izolovaná (VLAN doporučeno) -- žádný přístup
      do zbytku tvé sítě
- [ ] `make firewall` aplikován, ověřen testem (viz DEPLOYMENT.md krok 5)
- [ ] `.env` má vlastní hesla, ne defaulty z `.env.example`
- [ ] Grafana/session-viewer nejsou dostupné z internetu (jen z ADMIN_CIDR)
- [ ] Skutečný SSH admin port není z WAN dostupný
- [ ] Snapshot VM v čistém stavu
- [ ] Máš plán na pravidelný reset (viz níže)
- [ ] `cowrie.cfg` má `backend = shell` (ne proxy/llm)
- [ ] Máš plán/retenci pro logy s IP adresami (viz GDPR níže)

## Pravidelný reset

Doporučeno periodicky (týdně) obnovit VM ze snapshotu -- smaže
jakoukoli perzistentní kontaminaci fake filesystému a resetuje stav
po případném selhání. **Před resetem zazálohuj logy a stažené
vzorky** (Docker volumes `cowrie-var-log`, `cowrie-var-lib`) -- to
jsou data, která chceš uchovat.

## GDPR / právní

IP adresy útočníků jsou osobní údaje (jsi-li v EU). Provoz honeypotu
za účelem bezpečnosti sítě je obvykle kryt oprávněným zájmem (čl.
6/1/f GDPR), ale:
- neuváděj/nepublikuj syrové logy s IP veřejně
- měj definovanou retenci (`LOKI_RETENTION_HOURS` v `.env`)
- při sdílení threat intelu (blog, komunita) agreguj/anonymizuj

## Co dělat, když uvidíš `HONEYPOT-EGRESS-BLOCKED`

1. Zkontroluj, o jaké spojení šlo (`journalctl -k | grep EGRESS-BLOCKED`)
2. Pokud je to legitimní potřeba (např. jiný port pro download), uprav
   `scripts/firewall.sh` vědomě -- nerozšiřuj naslepo
3. Pokud vypadá podezřele (spojení, které jsi nečekal, na neobvyklý
   port/IP) -- ihned izoluj VM (odpoj síť), zkontroluj Grafana
   dashboard a syrové logy, zvaž, že šlo o pokus o únik z emulace

## Anti-detekce

Viz [ANTI-DETECTION.md](ANTI-DETECTION.md) -- jak honeypot vypadá
méně nápadně, a proč to má limity.
