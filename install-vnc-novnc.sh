#!/bin/bash

# Проверка прав администратора
if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт с правами root: sudo ./$(basename "$0")"
    exit 1
fi

# Обновление системы
apt update && apt upgrade -y

# Установка x11vnc и зависимостей
apt install -y x11vnc net-tools git python3-websockify

# Настройка x11vnc
echo -n "Установите пароль для VNC: "
x11vnc -storepasswd /etc/x11vnc.pass
chmod 600 /etc/x11vnc.pass

# Установка noVNC
cd /opt
git clone https://github.com/novnc/noVNC.git
cd noVNC
git checkout v1.4.0  # Используем стабильную версию

# Создание сервиса для x11vnc
cat > /etc/systemd/system/x11vnc.service << EOF
[Unit]
Description=x11vnc service
After=display-manager.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SUDO_USER
ExecStart=/usr/bin/x11vnc -auth guess -display :0 -forever -loop -noxdamage -repeat -rfbauth /etc/x11vnc.pass -rfbport 5900 -shared
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Создание сервиса для noVNC
cat > /etc/systemd/system/novnc.service << EOF
[Unit]
Description=noVNC service
After=network.target x11vnc.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/noVNC
ExecStart=/usr/bin/websockify --web /opt/noVNC 6080 localhost:5900
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Активация сервисов
systemctl daemon-reload
systemctl enable x11vnc
systemctl start x11vnc
systemctl enable novnc
systemctl start novnc

# Проверка статуса
echo -e "\n\033[1;32mУстановка завершена!\033[0m"
echo "Статус x11vnc:"
systemctl status x11vnc --no-pager | head -5
echo -e "\nСтатус noVNC:"
systemctl status novnc --no-pager | head -5

# Инструкция
IP=$(hostname -I | awk '{print $1}')
echo -e "\n\033[1;34mДоступ через VNC-клиент:\033[0m"
echo "Адрес: $IP порт 5900"
echo "Пароль: тот, который вы установили ранее"
echo -e "\n\033[1;34mДоступ через браузер (noVNC):\033[0m"
echo "http://$IP:6080/vnc.html"
echo -e "\n\033[1;33mВнимание:\033[0m noVNC использует незашифрованное соединение. Для безопасности рекомендуется:"
echo "1. Настроить брандмауэр"
echo "2. Использовать VPN или SSH-туннель"
echo "3. Регулярно менять пароль"