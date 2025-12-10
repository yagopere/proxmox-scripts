#!/bin/bash

# =============================================
# Скрипт для установки Ollama + Open WebUI в LXC на Proxmox
# Автоматически создает VM и настраивает все компоненты
# =============================================

# Настройки
LXC_NAME="ollama-webui1"
LXC_VMID=9999  # Уникальный номер VM в Proxmox
LXC_CPU="2"
LXC_RAM="4G"
LXC_DISK="40G"
LXC_NETWORK="vmbr0"
LXC_OS="debian-12"
LXC_IP="192.168.1.100/24"  # Измените на свой IP
LXC_GATEWAY="192.168.1.1"
LXC_DNS="8.8.8.8"

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: Скрипт должен запускаться от root!"
    exit 1
fi

# Проверка наличия Proxmox CLI
if ! command -v pct &> /dev/null; then
    echo "Ошибка: Proxmox CLI не найден. Установите pve-tools."
    exit 1
fi

# =============================================
# Функция создания LXC-машины
# =============================================
create_lxc() {
    echo "Создание LXC-машины $LXC_NAME (VMID: $LXC_VMID)..."

    # Создаем базовую VM из шаблона
    pct create $LXC_VMID --memory $LXC_RAM --cores $LXC_CPU --disk $LXC_DISK --netvm $LXC_NETWORK --ostype $LXC_OS --hostname ollama-webui --unattended

    # Настраиваем сетевой интерфейс
    pvesh set /nodes/pve/vms/$LXC_VMID/config --network0 name=eth0,bridge=$LXC_NETWORK,ip=$LXC_IP,ip6=none,gw=$LXC_GATEWAY,dns=$LXC_DNS

    # Запускаем VM
    pct start $LXC_VMID

    # Ожидаем готовность VM (5 минут)
    echo "Ожидание готовности VM (5 минут)..."
    sleep 300

    # Проверяем IP-адрес
    IP=$(pct config $LXC_VMID | grep -oP 'ip=.*?/')
    if [ -z "$IP" ]; then
        echo "Ошибка: Не удалось определить IP-адрес LXC!"
        pct stop $LXC_VMID
        pct destroy $LXC_VMID
        exit 1
    fi

    echo "LXC-машина успешно создана! IP: $IP"
    return 0
}

# =============================================
# Функция установки Ollama и Open WebUI
# =============================================
install_ollama_webui() {
    echo "Установка Ollama и Open WebUI в LXC ($LXC_NAME)..."

    # Подключаемся к LXC (через pveguesthelper)
    pct enter $LXC_VMID

    # Обновляем систему
    apt-get update && apt-get upgrade -y

    # Устанавливаем зависимости
    apt-get install -y curl wget apt-transport-https ca-certificates gnupg lsb-release

    # Устанавливаем Docker (без конфликтов с Proxmox)
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb-release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Добавляем пользователя в группу Docker
    usermod -aG docker $USER

    # Устанавливаем Ollama
    curl -fsSL https://ollama.com/install.sh | sh

    # Запускаем Ollama в фоновом режиме
    ollama serve &

    # Устанавливаем Open WebUI
    docker run -d \
      --name openwebui \
      -e OLLAMA_BASE_URL=http://localhost:11434 \
      -e OLLAMA_API_KEY="" \
      -p 8080:8080 \
      ghcr.io/open-webui/open-webui:main

    # Загружаем модель (Llama2)
    ollama pull llama2

    # Проверяем доступность Open WebUI
    echo "Open WebUI доступен по адресу: http://$IP:8080"
    echo "Проверьте логи Docker для диагностики:"
    echo "docker logs openwebui"
}

# =============================================
# Основной скрипт
# =============================================
main() {
    # Проверяем, существует ли уже VM
    if pct list | grep -q "$LXC_NAME"; then
        echo "VM $LXC_NAME уже существует!"
        read -p "Хотите продолжить установку? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        create_lxc || exit 1
    fi

    # Устанавливаем Ollama и Open WebUI
    install_ollama_webui || exit 1
}

main
