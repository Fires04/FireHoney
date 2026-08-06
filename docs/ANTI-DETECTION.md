# Anti-detekce

Cowrie (jako většina SSH honeypotů) má několik rozpoznatelných
"otisků prstů". Tenhle dokument shrnuje, co nás prozrazuje, co jsme
udělali proti tomu, a proč tomu nevěnujeme neomezené úsilí.

## Realita provozu

Naprostá většina provozu, co na veřejnou IP na portu 22/23 dopadne,
jsou **automatizovaní boti a scannery** (Mirai varianty,
credential-stuffing skripty). Ty honeypot detekci vůbec neřeší, jen
mechanicky zkoušejí creds a spouští naučené příkazy -- to je přesně
to, co chceš studovat, a na to Cowrie stačí beze změny. Cílená
detekce honeypotu je relevantní hlavně pro sofistikovaného lidského
útočníka nebo red-teamera.

## Co nás prozrazuje

1. **Permisivní `userdb.txt`** -- útočník zkusí nesmyslné heslo, na
   reálném serveru to spadne. Hlavní tell, ale i hlavní zdroj dat.
2. **Emulovaný shell má díry** -- Cowrie neemuluje coreutils dokonale
   (např. `head -3`/`tail -3` s číselnou zkratkou selže). Nedá se to
   snadno opravit bez patchování Cowrie samotného.
3. **Generický fake filesystem** -- výchozí `fs.pickle` je stejný pro
   každou Cowrie instalaci na světě.
4. **SSH `kex`/`hassh` fingerprint** -- existují veřejné nástroje
   (i Shodan Honeyscore), co ho aktivně testují.
5. **Chování při zátěži** -- reálný server pod brute-force zpomalí,
   Cowrie okamžitě a nekonečně přijímá spojení.

## Co je naopak v pořádku

- TCP/IP stack je **skutečný** (běží na reálném Debian kernelu v
  Docker kontejneru) -- nízkoúrovňové otisky (p0f) sedí
- SSH banner odpovídá kernelu (`OpenSSH_9.2p1 Debian-12` + `uname`
  hlásící Debian 12 kernel) -- interně konzistentní

## Co tenhle projekt dělá proti tomu

### 1. Realistický fake filesystem (`make fakefs`)

`scripts/build-fakefs.sh` postaví jednorázový `debian:12-slim`
kontejner s typickými balíčky (nginx, php, mariadb-client...) a
trochou "nepořádku" (`/var/www/html`, `/opt/app/.env`), vyexportuje
jeho filesystem a přes Cowrie vlastní nástroj `createfs` z něj udělá
`config/cowrie/fs.pickle`.

**Bezpečnostní poznámka:** `createfs` embeduje reálný OBSAH jen pro
pár pevných cest (`/etc/passwd`, `/etc/shadow`, `/etc/hostname`,
`/etc/os-release`, `/proc/cpuinfo`...). **Nikdy nespouštěj
`build-fakefs.sh` proti produkčnímu/reálnému hostu** -- zdrojem musí
být vždycky ten jednorázový, nesouvisející kontejner z
`docker/fakefs-builder/`. Kdyby se pustil proti reálnému stroji,
skutečný `/etc/shadow` s hashem tvého admin účtu by skončil čitelný
útočníkům v honeypotu.

Dva dílčí detaily, na které jsme narazili a `build-fakefs.sh` je řeší:
- `docker export` nepřenese obsah `/etc/hostname` (Docker ho
  spravuje mimo image vrstvu) -- skript ho dopisuje ručně po exportu.
- `/etc/os-release` je na reálném Debianu symlink na
  `/usr/lib/os-release`; `createfs` embeduje obsah jen u regulérních
  souborů, ne symlinků -- skript ho před generováním dereferencuje.

### 2. Vrstvený `userdb.txt`

Systémové účty (`www-data`, `mysql`, `nobody`...) mají explicitní
zákaz -- reálný server jim nastavuje shell na `/usr/sbin/nologin`,
takže by interaktivní login stejně neprošel. Root má navíc zamítnuté
čtyři nejběžnější "je-tohle-honeypot" canary kombinace
(`root/root`, `root/123456`, cokoliv obsahující "honeypot" nebo
"cowrie"). Všechno ostatní zůstává permisivní -- to je záměr, hlavní
zdroj dat.

**Past, na kterou jsme narazili:** Cowrie čte `userdb.txt` striktně
jako ASCII. Neanglické komentáře (diakritika) v souboru způsobí
`UnicodeDecodeError` při načítání, což shodí **úplně všechna**
přihlášení (fail-closed), ne jen ta záměrně zamítnutá -- vypadá to
jako "všechno je najednou rozbité", ne jako zjevná chyba konfigurace.
Drž `userdb.txt` i `cowrie.cfg` čistě v ASCII.

## Co jsme (zatím) neřešili

- Timing/protokolové otisky na úrovni Twisted async stacku (výzkum
  existuje, ale je to hlubší rabbit hole než má smysl pro domácí lab)
- Přesná shoda balíčkové databáze (`dpkg -l` výstup) s reálným
  systémem -- fake filesystem má strukturu, ne funkční `dpkg`
- Sdílení threat-intel dat (SANS DShield) -- viz `cowrie.cfg`
  komentovaná sekce `[output_dshield]`, vyžaduje vlastní firewall
  výjimku navíc
