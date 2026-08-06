.PHONY: setup up down restart logs ps firewall fakefs reset-cowrie pull update

setup:      ## Prvni priprava (htpasswd, asciinema-player, docker pull)
	./scripts/setup.sh

up:         ## Rozjede cely stack na pozadi
	docker compose up -d

down:       ## Zastavi a odstrani kontejnery (data ve volumes zustanou)
	docker compose down

restart:    ## Restartuje vsechny sluzby
	docker compose restart

reset-cowrie: ## Restartuje jen Cowrie (napr. po zmene cowrie.cfg/userdb.txt/fs.pickle)
	docker compose restart cowrie

logs:       ## Live log vsech sluzeb
	docker compose logs -f

ps:         ## Stav kontejneru
	docker compose ps

firewall:   ## Aplikuje egress lockdown (potrebuje root)
	sudo ./scripts/firewall.sh

fakefs:     ## Vygeneruje realisticky fake filesystem (config/cowrie/fs.pickle)
	./scripts/build-fakefs.sh

sessions:   ## Rucne spusti generator prehledu relaci hned (nemusis cekat na dalsi tik)
	docker compose exec session-generator python3 generate-sessions.py --once

pull:       ## Stahne nejnovejsi verze images + rebuild vlastnich
	docker compose pull cowrie promtail loki grafana session-viewer
	docker compose build session-generator

update: pull ## Stahne nove images a restartuje (pak znovu spust `make firewall`)
	docker compose up -d
	@echo "Nezapomen znovu spustit: sudo make firewall"

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'
