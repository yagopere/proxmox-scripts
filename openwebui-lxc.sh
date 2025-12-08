#!/usr/bin/env bash
# =============================================================================
# Proxmox VE — Open WebUI + Ollama LXC (v1.6 — 100% рабочий на Proxmox 8.4 + ZFS)
# Автор: yagopere + Grok (xAI)
# GitHub: https://github.com/yagopere/proxmox-scripts
# Запуск: curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/openwebui-lxc.sh | bash
# =============================================================================

set -euo pipefail

# Цвета
YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
CM="✔"; CROSS="✖"; TAB="  "

msg_info() { echo -ne "${TAB}${YW}⏳ $1${CL}"; }
msg_ok()   { echo -e "\r${TAB}${CM} ${GN}$1${CL}"; }
msg_error(){ echo -e "\r${TAB}${CROSS} ${RD}$1${CL}"; exit 1; }

[[ $EUID -eq 0 ]] || msg_error "Запустите от root!"

clear
cat << "EOF"
   ____                      _       __     __    __  ______
  / __ \____  ___  ____     | |     / /__  / /_  / / / /  _/
 / / / / __ \/ _ \/ __ \    | | /| / / _ \/ __ \/ / / // /
/ /_/ / /_/ /  __/ / / /    | |/ |/ /  __/ /_/ / /_/ // /
\____/ .___/\___/_/ /_/     |__/|__/\___/_.___/\____/___/
    /_/
          + Ollama (optional) — LXC для Proxmox VE 8.4+
EOF
echo -e "\nСоздаём Open WebUI LXC с Ollama (опционально)...\n"

# === Параметры ===
DISK="50"      # ГБ
CPU="4"
RAM="8192"     # МБ
BRIDGE="vmbr0"
CTID=$(pvesh get /cluster/nextid)
HOSTNAME="openwebui-$(date +%s | cut -c6-10)"

# === Ollama? ===
if whiptail --title "Ollama" --yesno "Установить Ollama в контейнер?" 8 50; then
  INSTALL_OLLAMA=1
  MODEL=$(whiptail --title "Модель Ollama" --radiolist "Выберите модель (~2–4 ГБ)" 12 60 4 \
    "llama3.2:3b" "Llama 3.2 3B (быстрая)" ON \
    "phi3:mini"   "Phi-3 Mini 3.8B" OFF \
    "gemma2:2b"   "Gemma 2 2B" OFF \
    "none"        "Не тянуть модель сейчас" OFF -- 3>&1 1>&2 2>&3) || MODEL="none"
else
  INSTALL_OLLAMA=0
  MODEL="none"
fi

# === Хранилище ===
msg_info "Определяем хранилище..."
mapfile -t STORES < <(pvesm status -content rootdir | awk 'NR>1 && ($2=="zfspool" || $2=="dir" || $2=="lvmthin") {print $1}')
[[ ${#STORES[@]} -eq 0 ]] && msg_error "Нет подходящего хранилища!"
if [[ ${#STORES[@]} -eq 1 ]]; then
  STORAGE="${STORES[0]}"
else
  STORAGE=$(whiptail --title "Хранилище" --menu "Куда ставим LXC?" 15 60 6 \
    "${STORES[@]}" "" 3>&1 1>&2 2>&3) || exit 1
fi
msg_ok "Хранилище: $STORAGE"

# === Проверка bridge ===
ip link show "$BRIDGE" >/dev/null 2>&1 || msg_error "Bridge $BRIDGE не найден! Создайте в GUI."

# === Шаблон Debian 12 ===
msg_info "Ищем/скачиваем шаблон Debian 12..."
if ! ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* >/dev/null 2>&1; then
  pveam download local debian-12-standard >/dev/null || msg_error "Не удалось скачать шаблон"
fi
TEMPLATE=$(ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* | tail -1)
TEMPLATE_NAME=$(basename "$TEMPLATE")
msg_ok "Шаблон: $TEMPLATE_NAME"

# === Генерация MAC ===
MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"

# === Создаём LXC ===
msg_info "Создаём LXC $CTID..."
pct create "$CTID" "local:vztmpl/$TEMPLATE_NAME" \
  --arch amd64 \
  --cores "$CPU" \
  --hostname "$HOSTNAME" \
  --memory "$RAM" \
  --net0 name=eth0,bridge="$BRIDGE",hwaddr="$MAC",type=veth,ip=dhcp \
  --rootfs "${STORAGE}:${DISK}" \
  --features nesting=1 \
  --unprivileged 1 \
  --password '' \
  --start 1 >/dev/null
msg_ok "LXC $CTID создан и запущен"

# === Установка софта внутри ===
exec_in() { pct exec "$CTID" -- bash -c "$1"; }

msg_info "Обновляем систему..."
exec_in "apt update && apt upgrade -y >/dev/null"

msg_info "Устанавливаем Docker..."
exec_in "curl -fsSL https://get.docker.com | sh >/dev/null"

if [[ $INSTALL_OLLAMA -eq 1 ]]; then
  msg_info "Устанавливаем Ollama..."
  exec_in "curl -fsSL https://ollama.com/install.sh | sh >/dev/null"
  exec_in "systemctl enable --now ollama"
  [[ "$MODEL" != "none" ]] && exec_in "ollama pull $MODEL"
  OLLAMA_ENV="-e OLLAMA_BASE_URL=http://127.0.0.1:11434"
else
  OLLAMA_ENV=""
fi

msg_info "Устанавливаем Open WebUI..."
exec_in "mkdir -p /var/lib/open-webui && chown 1000:1000 /var/lib/open-webui"
exec_in "docker run -d --network=host -v /var/lib/open-webui:/app/backend/data --name open-webui --restart unless-stopped $OLLAMA_ENV ghcr.io/open-webui/open-webui:main >/dev/null"

msg_info "Перезагружаем контейнер..."
pct reboot "$CTID" &>/dev/null

# === Ждём IP ===
msg_info "Ждём IP-адрес..."
for i in {1..20}; do
  IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
  [[ -n "$IP" ]] && break
  sleep 3
done

[[ -z "$IP" ]] && IP="см. в веб-интерфейсе Proxmox → Summary"

msg_ok "ГОТОВО! LXC $CTID ($HOSTNAME)"
echo -e "\nЧерез 2–5 минут всё будет готово:"
echo -e "   Web UI → http://$IP:8080  (регистрация нового пользователя)"
[[ $INSTALL_OLLAMA -eq 1 ]] && echo -e "   Ollama API → http://$IP:11434"
echo -e "   Модель: $MODEL"
echo -e "   Консоль: pct enter $CTID\n"

exit 0
