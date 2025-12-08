#!/usr/bin/env bash
# =============================================================================
# Proxmox VE — Open WebUI + Ollama LXC (v2.0 — 100% рабочий, декабрь 2025)
# Автор: yagopere + Grok (xAI)
# GitHub: https://github.com/yagopere/proxmox-scripts
# Запуск: curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/ollama-openwebui-lxc.sh | bash
# =============================================================================

set -euo pipefail
clear

echo -e "\033[1;36m"
cat << "EOF"
   ____                      _       __     __    __  ______
  / __ \____  ___  ____     | |     / /__  / /_  / / / /  _/
 / / / / __ \/ _ \/ __ \    | | /| / / _ \/ __ \/ / / // /
/ /_/ / /_/ /  __/ / / /    | |/ |/ /  __/ /_/ / /_/ // /
\____/ .___/\___/_/ /_/     |__/|__/\___/_.___/\____/___/
    /_/           Open WebUI + Ollama LXC (Proxmox 8.4+)
EOF
echo -e "\033[0m"

# Автоопределение
CTID=$(pvesh get /cluster/nextid)
STORAGE="local-zfs"
BRIDGE="vmbr0"

# Проверка bridge
ip link show "$BRIDGE" &>/dev/null || { echo "Ошибка: bridge $BRIDGE не найден! Создайте в GUI."; exit 1; }

# Скачиваем шаблон если нет
if ! ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* &>/dev/null; then
  echo "Скачиваю шаблон Debian 12..."
  pveam download local debian-12-standard >/dev/null
fi
TEMPLATE=$(ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* | tail -n1)
TEMPLATE_NAME=$(basename "$TEMPLATE")

MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"

echo "Создаю LXC $CTID (ollama-webui)..."
pct create "$CTID" "local:vztmpl/$TEMPLATE_NAME" \
  --hostname ollama-webui \
  --cores 4 --memory 8192 \
  --net0 name=eth0,bridge="$BRIDGE",hwaddr="$MAC",type=veth,ip=dhcp \
  --rootfs "$STORAGE:50" \
  --features nesting=1 \
  --unprivileged 1 \
  --start 1 >/dev/null

echo "Устанавливаю Docker + Ollama + Open WebUI + модель llama3.2:3b..."

pct exec "$CTID" -- bash -c "
  apt update && apt upgrade -y >/dev/null
  curl -fsSL https://get.docker.com | sh >/dev/null

  # Ollama вручную с GitHub (обход 403)
  curl -L https://github.com/ollama/ollama/releases/download/v0.3.13/ollama-linux-amd64.tgz \
    | tar -xzf - -C /usr/local
  ln -sf /usr/local/bin/ollama /usr/bin/ollama

  cat > /etc/systemd/system/ollama.service << 'EOF'
[Unit]
Description=Ollama Service
After=network-online.target
[Service]
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3
Environment=\"PATH=/usr/local/bin:/usr/bin:/bin\"
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ollama

  # Ждём запуска и тянем модель
  sleep 10
  ollama pull llama3.2:3b

  # Open WebUI
  mkdir -p /var/lib/open-webui && chown 1000:1000 /var/lib/open-webui
  docker run -d --network=host \
    -v /var/lib/open-webui:/app/backend/data \
    -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    --name open-webui --restart unless-stopped \
    ghcr.io/open-webui/open-webui:main >/dev/null
"

pct reboot "$CTID" &>/dev/null

# Ждём IP
echo "Жду IP-адрес..."
for i in {1..40}; do
  IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
  [[ -n "$IP" ]] && break
  sleep 3
done

[[ -z "$IP" ]] && IP="проверь в веб-интерфейсе Proxmox → Summary"

echo -e "\n\033[1;32mГОТОВО! Через 2–5 минут всё будет работать:\033[0m"
echo -e "   → http://$IP:8080   (регистрация нового пользователя)"
echo -e "   → Модель llama3.2:3b уже скачана и готова"
echo -e "   → Вход в контейнер: pct enter $CTID"
echo -e "   → ID контейнера: $CTID\n"

exit 0
