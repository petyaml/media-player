#!/bin/bash

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт с правами root (sudo $0)"
    exit 1
fi

# Установка таймзоны
timedatectl set-timezone Europe/Moscow

# Установка имени компьютера
read -p "Введите имя компьютера: " hostname
hostnamectl set-hostname "$hostname"

# Определение сетевого интерфейса
default_interface=$(ip route | awk '/default/ {print $5}' | head -n1)
if [ -z "$default_interface" ]; then
    default_interface="eth0"
fi

# Настройка сети
echo -e "\nНастройка сети (текущий интерфейс: $default_interface)"
read -p "Использовать DHCP? [y/n]: " use_dhcp

# Создаем временный файл конфигурации
TMP_NETPLAN=$(mktemp)
if [[ "$use_dhcp" =~ ^[Yy]$ ]]; then
    cat > "$TMP_NETPLAN" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $default_interface:
      dhcp4: true
EOF
else
    read -p "Введите статический IP (например, 192.168.1.100/24): " static_ip
    read -p "Введите шлюз: " gateway
    read -p "Введите DNS серверы (через запятую): " dns_servers

    cat > "$TMP_NETPLAN" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $default_interface:
      addresses:
        - $static_ip
      routes:
        - to: default
          via: $gateway
      nameservers:
        addresses: [$dns_servers]
EOF
fi

# Копируем с правильными правами
install -m 600 "$TMP_NETPLAN" /etc/netplan/00-armbian-config.yaml
rm -f "$TMP_NETPLAN"

# Применяем настройки сети
netplan generate
netplan apply
systemctl restart systemd-networkd

# Установка необходимых пакетов
apt update
apt install -y samba vlc vlc-plugin-base inotify-tools watchdog lightdm

# Создание директории
mkdir -p /usr/share/reklama

# Настройка прав на директорию (исправлено для Samba)
chmod 1777 /usr/share/reklama  # sticky bit + полные права
setfacl -d -m u::rwx,g::rwx,o::rwx /usr/share/reklama  # наследуемые права

# Настройка Samba
cat >> /etc/samba/smb.conf <<EOF

[reklama]
path = /usr/share/reklama
browseable = yes
writable = yes
guest ok = yes
guest only = yes
force user = nobody
force group = nogroup
create mask = 0777
directory mask = 0777
map to guest = bad user
EOF

# Перезапуск Samba
systemctl restart smbd nmbd
smbpasswd -a nobody -n  # Создаем пустой пароль для nobody

# Настройка автологина
echo -e "\nНастройка автоматического входа:"
read -p "Введите имя пользователя для автологина: " username

# Создание пользователя если нужно
if ! id "$username" &>/dev/null; then
    echo "Создание пользователя $username"
    adduser --disabled-password --gecos "" "$username"
    read -sp "Введите пароль для $username: " userpass
    echo
    echo "$username:$userpass" | chpasswd
fi

# Создание скрипта для генерации плейлиста
cat > /usr/local/bin/generate_playlist.sh <<'EOF'
#!/bin/bash
DIR="/usr/share/reklama"
PLAYLIST="$DIR/playlist.m3u"

# Удаляем старый плейлист
rm -f "$PLAYLIST"

# Создаем плейлист: сначала видео, потом изображения
find "$DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.mkv" \) | sort > "$PLAYLIST"
find "$DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | sort >> "$PLAYLIST"

# Устанавливаем правильные права
chmod 666 "$PLAYLIST"
EOF
chmod +x /usr/local/bin/generate_playlist.sh

# Генерация начального плейлиста
/usr/local/bin/generate_playlist.sh

# Создание сервиса для VLC с поддержкой изображений
cat > /etc/systemd/system/vlc_player.service <<EOF
[Unit]
Description=VLC Player Service
After=graphical.target
Requires=graphical.target

[Service]
User=$username
Environment="DISPLAY=:0"
Environment="XAUTHORITY=/home/$username/.Xauthority"
ExecStartPre=/bin/sleep 15
# Используем плейлист и параметры для изображений
ExecStart=/usr/bin/vlc --fullscreen --no-video-title-show --quiet --loop \
         --image-duration=10 --no-audio /usr/share/reklama/playlist.m3u
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

# Создание вотчера для директории с улучшенной обработкой изображений
cat > /usr/local/bin/watch_folder.sh <<EOF
#!/bin/bash
USER="$username"
DIR="/usr/share/reklama"

while true; do
    # Используем более надежное отслеживание изменений
    inotifywait -r -e modify,create,delete,move,attrib "\$DIR"
    
    # Обновляем плейлист при любых изменениях
    /usr/local/bin/generate_playlist.sh
    
    # Проверяем, были ли изменения среди изображений
    image_changed=\$(find "\$DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -mmin -0.1)
    non_image_changed=\$(find "\$DIR" -maxdepth 1 -type f ! \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -mmin -0.1)
    
    # Если изменились только изображения, не перезапускаем VLC
    if [ -z "\$non_image_changed" ] && [ -n "\$image_changed" ]; then
        echo "Обновлены только изображения - перезапуск не требуется"
    else
        echo "Обнаружены изменения в видео или структуре файлов - перезапуск VLC"
        pkill -f "vlc --fullscreen"
        sleep 3
    fi
done
EOF
chmod +x /usr/local/bin/watch_folder.sh

# Создание сервиса для вотчера
cat > /etc/systemd/system/watch_folder.service <<EOF
[Unit]
Description=Folder Watcher Service
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/watch_folder.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Настройка watchdog
sed -i 's/#watchdog-device/watchdog-device/' /etc/watchdog.conf
sed -i 's/#max-load-1 = 24/max-load-1 = 24/' /etc/watchdog.conf
echo "SystemdCgroup = yes" >> /etc/watchdog.conf
systemctl enable watchdog
systemctl start watchdog

# Включение сервисов
systemctl daemon-reload
systemctl enable vlc_player.service
systemctl enable watch_folder.service
systemctl start watch_folder.service

# Настройка автологина для lightdm
cat > /etc/lightdm/lightdm.conf <<EOF
[Seat:*]
autologin-user=$username
autologin-user-timeout=0
user-session=xfce
greeter-session=lightdm-greeter
EOF

# Настройка автозапуска VLC в XFCE
mkdir -p /home/$username/.config/autostart
cat > /home/$username/.config/autostart/vlc.desktop <<EOF
[Desktop Entry]
Type=Application
Exec=systemctl --user start vlc_player
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=VLC Player
Comment=Start VLC player on login
EOF
chown -R $username:$username /home/$username/.config

# Настройка systemd user service
mkdir -p /home/$username/.config/systemd/user
cat > /home/$username/.config/systemd/user/vlc_player.service <<EOF
[Unit]
Description=VLC Player (User Service)
After=graphical-session.target

[Service]
ExecStart=/usr/bin/vlc --fullscreen --no-video-title-show --quiet --loop \
         --image-duration=10 --no-audio \
         /usr/share/reklama/playlist.m3u
Restart=always
RestartSec=5
Environment=DISPLAY=:0

[Install]
WantedBy=default.target
EOF
chown -R $username:$username /home/$username/.config

# Включение user сервиса
sudo -u $username DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u $username)/bus systemctl --user enable vlc_player.service

echo "Установка завершена! Требуется перезагрузка."
read -p "Перезагрузить сейчас? [y/n]: " reboot_ans
if [[ "$reboot_ans" =~ ^[Yy]$ ]]; then
    reboot
fi