#!/usr/bin/env bash

# =============================================================================
# Proxmox VE - Open WebUI LXC with optional Ollama (единый файл)
# Автор: yagopere + Grok (xAI), на основе community-scripts/ProxmoxVE
# GitHub: https://github.com/yagopere/proxmox-scripts
# Запуск: curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/openwebui-lxc.sh | bash
# =============================================================================

# Встроенные функции (адаптировано из build.func)
variables() {
  NSAPP="openwebui"
  APP="Open WebUI"
  var_disk="25"
  var_cpu="4"
  var_ram="8192"
  var_os="debian"
  var_version="12"
  var_unprivileged="1"
}

color() {
  YW="\033[33m"
  BL="\033[36m"
  RD="\033[01;31m"
  BGN="\033[4;92m"
  GN="\033[1;92m"
  DGN="\033[32m"
  CL="\033[m"
  CM="${GN}✔${CL}"
  CROSS="${RD}✘${CL}"
  BFR="\\r\\033[K"
  HOLD=" -"
}

catch_errors() {
  set -Eeuo pipefail
  trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
}

error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  exit $exit_code
}

msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

root_check() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Please run as root"
    exit 1
  fi
}

pve_check() {
  if ! pveversion | grep -Eq "pve-manager/8"; then
    msg_error "Requires Proxmox VE 8+"
    exit 1
  fi
}

arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    msg_error "Only x86_64 supported"
    exit 1
  fi
}

get_nextid() {
  local try_id=$(pvesh get /cluster/nextid)
  while [ -f "/etc/pve/lxc/${try_id}.conf" ] || [ -f "/etc/pve/qemu-server/${try_id}.conf" ]; do
    try_id=$((try_id + 1))
  done
  echo "$try_id"
}

# Основная функция
header_info() {
  clear
  cat <<"EOF"
   ____                      _       __     __    __  ______
  / __ \____  ___  ____     | |     / /__  / /_  / / / /  _/
 / / / / __ \/ _ \/ __ \    | | /| / / _ \/ __ \/ / / // /
/ /_/ / /_/ /  __/ / / /    | |/ |/ /  __/ /_/ / /_/ // /
\____/ .___/\___/_/ /_/     |__/|__/\___/_.___/\____/___/
    /_/

EOF
}

header_info
echo -e "Creating Open WebUI LXC with optional Ollama...\n"

root_check
pve_check
arch_check
variables
color
catch_errors

# Опции через whiptail
INSTALL_OLLAMA=$(whiptail --backtitle "Proxmox Open WebUI LXC" --title "Install Ollama?" --yesno "Install Ollama inside LXC?" 8 50 3>&1 1>&2 2>&3 && echo "yes" || echo "no")

MODEL_TO_PULL=""
if [ "$INSTALL_OLLAMA" == "yes" ]; then
  MODEL_CHOICE=$(whiptail --backtitle "Proxmox Open WebUI LXC" --title "Ollama Model" --radiolist \
    "Choose model to pull (~2–4 GB)" 12 50 4 \
    "llama3.2:3b" "Llama 3.2 (3B, fast)" ON \
    "phi3:mini" "Phi-3 Mini (3.8B)" OFF \
    "gemma2:2b" "Gemma 2 (2B)" OFF \
    "none" "None" OFF \
    3>&1 1>&2 2>&3) || MODEL_TO_PULL="none"
  MODEL_TO_PULL="$MODEL_CHOICE"
fi

# Выбор хранилища
msg_info "Detecting storage"
STORAGE_MENU=()
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  TYPE=$(echo "$line" | awk '{print $2}')
  FREE=$(echo "$line" | awk '{print $6 "G"}')
  [[ $TYPE == "zfspool" || $TYPE == "dir" || $TYPE == "lvmthin" || $TYPE == "btrfs" ]] && STORAGE_MENU+=("$TAG" "$TYPE – $FREE free" "OFF")
done < <(pvesm status -content rootdir | awk 'NR>1 {print $1, $2, $6}')

[[ ${#STORAGE_MENU[@]} -eq 0 ]] && msg_error "No suitable storage for LXC!"

if [[ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]]; then
  STORAGE=${STORAGE_MENU[0]}
else
  STORAGE=$(whiptail --title "Choose storage" --radiolist "Where to place LXC?" 15 70 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit 1
fi
msg_ok "Storage: $STORAGE"

# Создание LXC
CTID=$(get_nextid)
HN="openwebui-lxc"
DISK_SIZE="$var_disk"G
CORE_COUNT="$var_cpu"
RAM_SIZE="$var_ram"

TEMPLATE_SEARCH="$var_os-$var_version"
templates=($(pveam available -section system | sed -n "s/.*\($TEMPLATE_SEARCH.*\)/\1/p" | sort -r))
TEMPLATE="${templates[0]}"
if [ -z "$TEMPLATE" ]; then
  msg_error "No $TEMPLATE_SEARCH template found."
  exit 1
fi

msg_info "Downloading template"
pveam download local $TEMPLATE >/dev/null
msg_ok "Downloaded template"

msg_info "Creating LXC $CTID"
GEN_MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//' | tr a-f A-F)"
pct create $CTID local:vztmpl/${TEMPLATE} -arch amd64 -cores $CORE_COUNT -hostname $HN -memory $RAM_SIZE -net0 name=eth0,bridge=vmbr0,ip=dhcp,macaddr=$GEN_MAC -ostype $var_os -rootfs $STORAGE:$DISK_SIZE -swap 1024 -unprivileged $var_unprivileged
msg_ok "Created LXC"

msg_info "Starting LXC"
pct start $CTID
sleep 5
msg_ok "Started LXC"

# Установка внутри LXC
exec_in() { pct exec $CTID -- bash -c "$1"; }

msg_info "Updating packages"
exec_in "apt-get update && apt-get upgrade -y >/dev/null"
msg_ok "Updated packages"

msg_info "Installing dependencies"
exec_in "apt-get install -y curl wget ca-certificates gnupg >/dev/null"
msg_ok "Installed dependencies"

msg_info "Installing Docker"
exec_in "install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && chmod a+r /etc/apt/keyrings/docker.asc"
exec_in 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list'
exec_in "apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null"
msg_ok "Installed Docker"

if [ "$INSTALL_OLLAMA" == "yes" ]; then
  msg_info "Installing Ollama"
  exec_in "curl -fsSL https://ollama.com/install.sh | sh >/dev/null"
  exec_in "systemctl enable --now ollama"
  if [ "$MODEL_TO_PULL" != "none" ]; then
    exec_in "ollama pull $MODEL_TO_PULL >/dev/null"
  fi
  msg_ok "Installed Ollama"
  OLLAMA_ENV="-e OLLAMA_BASE_URL=http://127.0.0.1:11434"
else
  OLLAMA_ENV=""
fi

msg_info "Installing Open WebUI"
exec_in "mkdir -p /var/lib/open-webui"
exec_in "docker run -d --network=host -v /var/lib/open-webui:/app/backend/data --name open-webui --restart always $OLLAMA_ENV ghcr.io/open-webui/open-webui:main >/dev/null"
msg_ok "Installed Open WebUI"

msg_info "Setting features (nesting for Docker)"
pct set $CTID -features nesting=1
msg_ok "Set features"

msg_info "Restarting LXC"
pct reboot $CTID
sleep 10
msg_ok "Restarted LXC"

# Получение IP
IP=$(pct exec $CTID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "N/A")

msg_ok "Done! LXC $CTID ($HN) created."
echo -e "\nThrough 2–5 minutes everything will be ready:"
echo -e "   ➜ Web UI: http://${IP}:8080 (register new user)"
echo -e "   ➜ Ollama API: http://${IP}:11434 (if installed)"
echo -e "   ➜ SSH: ssh root@${IP} (auto-login if no password)"
echo -e "   ➜ Model: $MODEL_TO_PULL\n"

exit 0
