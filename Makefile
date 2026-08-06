.PHONY: setup up down restart logs ps firewall fakefs sessions reset-cowrie pull update

setup:      ## First-time setup (htpasswd, asciinema-player, docker pull)
	./scripts/setup.sh

up:         ## Bring up the whole stack in the background
	docker compose up -d

down:       ## Stop and remove containers (data in volumes is kept)
	docker compose down

restart:    ## Restart all services
	docker compose restart

reset-cowrie: ## Restart just Cowrie (e.g. after changing cowrie.cfg/userdb.txt/fs.pickle)
	docker compose restart cowrie

logs:       ## Live logs from all services
	docker compose logs -f

ps:         ## Container status
	docker compose ps

firewall:   ## Apply the egress lockdown (needs root)
	sudo ./scripts/firewall.sh

fakefs:     ## Generate a realistic fake filesystem (config/cowrie/fs.pickle)
	./scripts/build-fakefs.sh

sessions:   ## Run the session-overview generator right now (don't wait for the next tick)
	docker compose exec session-generator python3 generate-sessions.py --once

pull:       ## Pull the latest images + rebuild our own
	docker compose pull cowrie promtail loki grafana session-viewer
	docker compose build session-generator

update: pull ## Pull new images and restart (then re-run `make firewall`)
	docker compose up -d
	@echo "Don't forget to re-run: sudo make firewall"

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'
