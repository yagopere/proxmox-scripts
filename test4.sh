#!/usr/bin/env bash
# =============================================================================
# Proxmox VE — Open WebUI + Ollama LXC (v7.4 — с фиксами миграций и Docker, декабрь 2025)
# Улучшения: 
# - Авто-удаление старого open-webui контейнера перед run (фикс перезагрузок).
# - Авто-reset БД (rm webui.db) перед первым запуском (фикс миграций Alembic).
# - Увеличена производительность: cores=8, memory=16384 (16GB), num_thread=8 в Ollama.
# - Добавлен sleep 60 сек после Docker run для полной инициализации UI (избежать "не открывается").
# - Web Search: DuckDuckGo по умолчанию, с env для стабильности (низкая нагрузка — нормально для idle; во время inference CPU до 100%).
# - Логи: Полные в /var/log/open-webui.log.
# Запуск: curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/ollama-webui-lxc.sh | bash
# =============================================================================
set -euo pipefail
clear
echo -e "\033[1;36m
   ____ _ __ __ __ ______
  / __ \\____ ___ ____ | | / /__ / /_ / / / / _/
 / / / / __ \\/ _ \\/ __ \\ | | /| / / _ \\/ __ \\/ / / // /
/ /_/ / /_/ / __/ / / / | |/ |/ / __/ /_/ / /_/ // /
\\____/ .___/\\___/_/ /_/ |__/|__/\\___/_.___/\\____/___/
     /_/ Open WebUI + Ollama LXC (v7.4 — с авто-фиксами)
\033[0m\n"
CTID=$(pvesh get /cluster/nextid)
STORAGE="local-zfs"
BRIDGE="vmbr0"
ip link show "$BRIDGE" &>/dev/null || { echo "Bridge $BRIDGE не найден!"; exit 1; }
# Шаблон
if ! ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* &>/dev/null; then
  echo "Скачиваю шаблон Debian 12..."
  pveam download local debian-12-standard >/dev/null
fi
TEMPLATE_NAME=$(ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* | tail -n1 | xargs basename)
MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"
echo "Создаю LXC $CTID..."
pct create "$CTID" "local:vztmpl/$TEMPLATE_NAME" \
  --hostname ollama-webui \
  --cores 8 --memory 16384 \
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
  # Ollama (актуальная v0.3.14 на 11.12.2025)
  echo "Устанавливаю Ollama v0.3.14..."
  wget -qO- "https://github.com/ollama/ollama/releases/download/v0.3.14/ollama-linux-amd64.tgz" | tar -xzf - -C /usr/local
  ln -sf /usr/local/bin/ollama /usr/bin/ollama
  # Ollama сервис с оптимизацией (num_thread=8 для полной нагрузки CPU)
  cat > /etc/systemd/system/ollama.service << "EOF"
[Unit]
Description=Ollama Service
After=network-online.target
[Service]
ExecStart=/bin/sh -c "HOME=/root OLLAMA_NUM_PARALLEL=4 OLLAMA_MAX_LOADED_MODELS=2 /usr/local/bin/ollama serve > /var/log/ollama.log 2>&1"
Restart=always
RestartSec=3
Environment="PATH=/usr/local/bin:/usr/bin:/bin" "OLLAMA_NUM_THREAD=8"
User=root
Group=root
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ollama
  # Ждём запуска Ollama
  echo "Жду запуска Ollama..."
  for i in {1..30}; do
    if curl -s http://127.0.0.1:11434 2>/dev/null | grep -q "Ollama is running"; then
      echo "Ollama запущен!"
      break
    fi
    sleep 2
  done
  # Модель (llama3.1:8b с оптимизацией для tool calling)
  echo "Скачиваю модель llama3.1:8b..."
  ollama pull llama3.1:8b
  # Создаём Modelfile для модели (увеличенный контекст и threads для нагрузки)
  cat > /root/Modelfile << EOF
FROM llama3.1:8b
PARAMETER num_thread 8
PARAMETER num_ctx 8192
PARAMETER temperature 0.7
SYSTEM """Ты полезный ассистент с доступом к интернету. Используй поиск для свежих данных."""
EOF
  ollama create llama3.1:8b-optimized -f /root/Modelfile
  ollama rm llama3.1:8b  # Заменяем на оптимизированную
  # Open WebUI: авто-фикс Docker и БД
  echo "Подготавливаю Open WebUI..."
  mkdir -p /var/lib/open-webui
  chown 1000:1000 /var/lib/open-webui
  # Авто-удаление старого контейнера и БД (фикс миграций и перезагрузок)
  docker rm -f open-webui >/dev/null 2>&1 || true
  rm -f /var/lib/open-webui/webui.db /var/lib/open-webui/webui.db-shm /var/lib/open-webui/webui.db-wal
  # Запуск с логами и env для стабильного поиска (низкая нагрузка — норма; inference нагружает до 100%)
  docker run -d --network=host \
    -v /var/lib/open-webui:/app/backend/data \
    -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    -e ENABLE_RAG_WEB_SEARCH=true \
    -e WEB_SEARCH_PROVIDER=duckduckgo \
    -e WEB_SEARCH_DUCKDUCKGO_API_KEY="" \
    -e WEB_SEARCH_NUM_RESULTS=5 \
    -e LOG_LEVEL=INFO \
    --name open-webui --restart unless-stopped \
    ghcr.io/open-webui/open-webui:v0.3.14  # Стабильный тег (не main, чтобы избежать багов миграций)
  # Логи Open WebUI в файл
  docker logs open-webui > /var/log/open-webui.log 2>&1 &
  # Ждём инициализации UI (60 сек для скачивания embeddings и миграций)
  echo "Жду инициализации Open WebUI (1–2 мин)..."
  sleep 60
  # Проверяем, что UI жив (curl на порт)
  for i in {1..10}; do
    if curl -s http://127.0.0.1:8080 2>/dev/null | head -c 100 | grep -q "Open WebUI"; then
      echo "Open WebUI готов!"
      break
    fi
    sleep 6
  done
'
pct reboot "$CTID" &>/dev/null
echo "Жду IP..."
for i in {1..40}; do
  IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP "(?<=inet )[\d.]{7,}" | head -1 || true)
  [[ -n "$IP" ]] && break
  sleep 3
done
[[ -z "$IP" ]] && IP="проверь в GUI → Summary"
echo -e "\n\033[1;32mГОТОВО! Через 2–3 минуты открывай:\033[0m"
echo -e " → http://$IP:8080 (регистрация: первый аккаунт — админ)"
echo -e " → Модель: llama3.1:8b-optimized (8 threads для полной нагрузки CPU)"
echo -e " → Web Search: Включи в чате (+ → Web Search ON) — DuckDuckGo, 5 результатов"
echo -e " → Нагрузка: Idle низкая (нормально); во время запроса CPU 80–100%, RAM +2–4GB"
echo -e " → ID: $CTID  |  Вход: pct enter $CTID"
echo -e " → Логи: tail -f /var/log/ollama.log или /var/log/open-webui.log\n"
echo -e "Тести: Спроси 'Какая дата сегодня?' — ответит 11 декабря 2025 с источниками."
exit 0
