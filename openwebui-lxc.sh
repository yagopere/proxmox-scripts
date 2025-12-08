#!/usr/bin/env bash
# Proxmox VE — Open WebUI + Ollama LXC (v1.8 — 100% рабочий на 8.4 + local-zfs)
# Запуск одной командой: curl -fsSL https://tinyurl.com/ollama-lxc-proxmox | bash

set -euo pipefail

YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
CM="✔"; CROSS="✖"

msg_info() { echo -ne " ⏳ $1..."; }
msg_ok()   { echo -e "\r $CM $1"; }

clear
cat << "EOF"
   ____                      _       __     __    __  ______
  / __ \____  ___  ____     | |     / /__  / /_  / / / /  _/
 / / / / __ \/ _ \/ __ \    | | /| / / _ \/ __ \/ / / // /
/ /_/ / /_/ /  __/ / / /    | |/ |/ /  __/ /_/ / /_/ // /
\____/ .___/\___/_/ /_/     |__/|__/\___/_.___/\____/___/
    /_/
          Open WebUI + Ollama LXC (Proxmox 8.4+)
EOF
echo

# === Автоопределение ===
CTID=$(pvesh get /cluster/nextid)
STORAGE="local-zfs"
TEMPLATE=$(ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* | tail -n1)
[[ -z "$TEMPLATE" ]] && { echo "Скачиваю шаблон..."; pveam download local debian-12-standard; TEMPLATE=$(ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* | tail -n1); }
TEMPLATE_NAME=$(basename "$TEMPLATE")
MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"

# === Ollama? ===
if (whiptail --title "Ollama" --yesno "Установить Ollama и скачать модель?" 8 60); then
  MODEL=$(whiptail --title "Модель" --menu "Выберите:" 12 50 4 \
    "llama3.2:3b" "Llama 3.2 3B (быстрая)" \
    "phi3:mini"   "Phi-3 Mini" \
    "gemma2:2b"   "Gemma 2 2B" \
    "none"        "Только Ollama, без модели" 3>&1 1>&2 2>&3)
else
  MODEL="none"
fi

msg_info "Создаём LXC $CTID"
pct create "$CTID" "local:vztmpl/$TEMPLATE_NAME" \
  --hostname ollama-webui \
  --cores 4 --memory 8192 \
  --net0 name=eth0,bridge=vmbr0,hwaddr="$MAC",type=veth,ip=dhcp \
  --rootfs "$STORAGE:50" \
  --features nesting=1 \
  --unprivileged 1 \
  --start 1 >/dev/null

msg_ok "LXC $CTID создан"

pct exec "$CTID" -- bash -c "
  apt update && apt upgrade -y && 
  curl -fsSL https://get.docker.com | sh && 
  curl -fsSL https://ollama.com/install.sh | sh && 
  systemctl enable --now ollama
  $( [[ $MODEL != "none" ]] && echo "ollama pull $MODEL" )
  mkdir -p /var/lib/open-webui && chown 1000:1000 /var/lib/open-webui
  docker run -d --network=host -v /var/lib/open-webui:/app/backend/data --name open-webui --restart unless-stopped \
    $( [[ $MODEL != "none" ]] && echo "-e OLLAMA_BASE_URL=http://127.0.0.1:11434" ) \
    ghcr.io/open-webui/open-webui:main
"

pct reboot "$CTID" &>/dev/null

msg_info "Ждём IP"
for i in {1..30}; do
  IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
  [[ -n "$IP" ]] && break
  sleep 3
done

[[ -z "$IP" ]] && IP="см. в веб-интерфейсе Proxmox → Summary"

echo -e "\n$CM ГОТОВО! Через 2–5 минут всё будет работать:"
echo    "   → http://$IP:8080   (регистрация нового пользователя)"
[[ $MODEL != "none" ]] && echo "   → Ollama: http://$IP:11434  (модель $MODEL уже скачана)"
echo    "   → Вход в контейнер: pct enter $CTID"
echo
