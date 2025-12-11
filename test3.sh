#!/usr/bin/env bash
# =============================================================================
# Proxmox VE — Open WebUI + Ollama LXC (v7.3 — чистая, без SearXNG, декабрь 2025)
# Убрано: SearXNG (из-за PEP 668 в Debian 12)
# Web Search: только DuckDuckGo (бесплатно, без ключа, работает сразу)
# =============================================================================
set -euo pipefail
clear
echo -e "\033[1;36m
   Open WebUI + Ollama LXC (v7.3 — чистая установка с Web Search)
\033[0m\n"
CTID=$(pvesh get /cluster/nextid)
STORAGE="local-zfs"
BRIDGE="vmbr0"
ip link show "$BRIDGE" &>/dev/null || { echo "Bridge $BRIDGE не найден!"; exit 1; }
if ! ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* &>/dev/null; then
  echo "Скачиваю шаблон Debian 12..."
  pveam download local debian-12-standard >/dev/null
fi
TEMPLATE_NAME=$(ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* | tail -n1 | xargs basename)
MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"
echo "Создаю LXC $CTID..."
pct create "$CTID" "local:vztmpl/$TEMPLATE_NAME" \
  --hostname ollama-webui \
  --cores 6 --memory 12288 \
  --net0 name=eth0,bridge="$BRIDGE",hwaddr="$MAC",type=veth,ip=dhcp \
  --rootfs "$STORAGE:50" \
  --features nesting=1 \
  --unprivileged 1 \
  --start 1 >/dev/null
echo "Устанавливаю всё внутри контейнера..."
pct exec "$CTID" -- bash -c '
  set -euo pipefail
  DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt upgrade -y
  apt install -y curl wget ca-certificates gnupg lsb-release locales
  # Фикс locale warnings
  sed -i "s/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
  locale-gen
  echo "LANG=en_US.UTF-8" > /etc/default/locale
  export LANG=en_US.UTF-8
  export LC_ALL=en_US.UTF-8
  # Docker
  curl -fsSL https://get.docker.com | sh
  # Ollama
  echo "Устанавливаю Ollama v0.13.2..."
  wget -qO- "https://github.com/ollama/ollama/releases/download/v0.13.2/ollama-linux-amd64.tgz" | tar -xzf - -C /usr/local
  ln -sf /usr/local/bin/ollama /usr/bin/ollama
  cat > /etc/systemd/system/ollama.service << "EOF"
[Unit]
Description=Ollama Service
After=network-online.target
[Service]
ExecStart=/bin/sh -c "HOME=/root /usr/local/bin/ollama serve > /var/log/ollama.log 2>&1"
Restart=always
RestartSec=3
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
User=root
Group=root
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ollama
  for i in {1..30}; do
    if curl -s http://127.0.0.1:11434 2>/dev/null | grep -q "Ollama is running"; then
      echo "Ollama запущен!"
      break
    fi
    sleep 2
  done
  echo "Скачиваю модель llama3.1:8b..."
  ollama pull llama3.1:8b
  # Open WebUI с Web Search (только DuckDuckGo — работает сразу)
  echo "Запускаю Open WebUI..."
  mkdir -p /var/lib/open-webui
  chown 1000:1000 /var/lib/open-webui
  docker run -d --network=host \
    -v /var/lib/open-webui:/app/backend/data \
    -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    -e ENABLE_RAG_WEB_SEARCH=true \
    -e WEB_SEARCH_PROVIDER=duckduckgo \
    -e WEB_SEARCH_DUCKDUCKGO_API_KEY="" \
    --name open-webui --restart unless-stopped \
    ghcr.io/open-webui/open-webui:main
'
pct reboot "$CTID" &>/dev/null
echo "Жду IP..."
for i in {1..40}; do
  IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP "(?<=inet )[\d.]{7,}" | head -1 || true)
  [[ -n "$IP" ]] && break
  sleep 3
done
[[ -z "$IP" ]] && IP="проверь в GUI → Summary"
echo -e "\n\033[1;32mГОТОВО! Установка чистая, без ошибок.\033[0m"
echo -e " → http://$IP:8080"
echo -e " → Web Search включён по умолчанию (DuckDuckGo)"
echo -e " → Модель llama3.1:8b готова"
echo -e " → ID: $CTID  |  Вход: pct enter $CTID"
echo -e " → После открытия UI: в чате нажми + → включи Web Search и спрашивай про дату!\n"
exit 0
