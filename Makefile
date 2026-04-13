.PHONY: install
install:
	curl -fsSL https://get.docker.com | sh
	sudo usermod -aG docker ${USER}
	newgrp docker

.PHONY: template
template:
	@MY_IP=$$(curl -s ifconfig.me) && \
	RANDOM_CODE=$$(openssl rand -hex 16) && \
	cp telemt.toml.template telemt.toml && \
	sed -i "s/<your_virtual_machine_ip>/$$MY_IP/g" telemt.toml && \
	sed -i "s/<your_generated_code>/$$RANDOM_CODE/g" telemt.toml && \
	echo "Config created: IP=$$MY_IP"


DOCKER_COMPOSE = docker compose

.PHONY: up
up:
	$(DOCKER_COMPOSE) up -d --build

.PHONY: logs
logs:
	$(DOCKER_COMPOSE) logs -f

.PHONY: down
down:
	$(DOCKER_COMPOSE) down

.PHONY: restart
restart:
	$(DOCKER_COMPOSE) down
	$(DOCKER_COMPOSE) up -d --build


.PHONY: amount
amount:
	@PID=$$(docker inspect -f '{{.State.Pid}}' telemt) && \
	awk 'NR>1 && $$4=="01"{c++} END{print c+0}' /proc/$$PID/net/tcp

DEV    := eth0
RATE   := 2mbps
BURST  := 256kbit

# Список актуальных CIDR-подсетей Telegram
TG_IPS := 91.108.4.0/22 \
          91.108.8.0/22 \
          91.108.12.0/22 \
          91.108.16.0/22 \
          91.108.20.0/22 \
          91.108.56.0/22 \
          91.105.192.0/23 \
          149.154.160.0/20 \
          185.76.151.0/24 \
          95.161.64.0/20

.PHONY: limit unlimit

limit:
	@echo "Настраиваем корневую дисциплину и классы (Default -> $(RATE))..."
	# 1. Корневая дисциплина HTB (все что не попало в фильтры идет в класс 20)
	sudo tc qdisc add dev $(DEV) root handle 1: htb default 20
	
	# 2. Создаем классы
	# Класс 1:10 — БЕЗЛИМИТ (1000mbit)
	sudo tc class add dev $(DEV) parent 1: classid 1:10 htb rate 1000mbit
	# Класс 1:20 — ЛИМИТ для клиентов (2mbps)
	sudo tc class add dev $(DEV) parent 1: classid 1:20 htb rate $(RATE) burst $(BURST)

	@echo "Добавляем SSH в безлимит..."
	# SSH (оставляем Безлимит)
	sudo tc filter add dev $(DEV) protocol ip parent 1: prio 1 u32 match ip sport 22 0xffff flowid 1:10
	sudo tc filter add dev $(DEV) protocol ip parent 1: prio 1 u32 match ip dport 22 0xffff flowid 1:10

	@echo "Добавляем сервера Telegram в безлимит..."
	# Цикл перебирает все IP из списка TG_IPS и добавляет для них разрешающее правило
	@for ip in $(TG_IPS); do \
		sudo tc filter add dev $(DEV) protocol ip parent 1: prio 1 u32 match ip dst $$ip flowid 1:10; \
		sudo tc filter add dev $(DEV) protocol ip parent 1: prio 1 u32 match ip src $$ip flowid 1:10; \
	done
	@echo "Готово! Трафик к Telegram исключен из ограничений."

unlimit:
	@echo "Снимаем ограничения..."
	sudo tc qdisc del dev $(DEV) root || true
	@echo "Ограничения сняты."

relimit: unlimit limit

status:
	@echo "=== Qdisc ==="
	@sudo tc qdisc show dev $(DEV)
	@echo "=== Classes ==="
	@sudo tc class show dev $(DEV)
	@echo "=== Filters ==="
	@sudo tc filter show dev $(DEV)

.PHONY: metrics
metrics:
	curl -s http://127.0.0.1:9090/metrics | grep 'user='
