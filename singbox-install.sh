#!/bin/sh

#set -x

# === Вспомогательные функции (должны быть первыми!) ===

error() {
    echo "$(date '+%F %T') [ERROR] $*" >&2
    exit 1
}

check_repo() {
    printf "\033[32;1mChecking OpenWrt repo availability...\033[0m\n"
    opkg update | grep -q "Failed to download" && printf "\033[31;1mopkg failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de\033[0m\n" && exit 1
}

route_vpn () {
cat << EOF > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh

sleep 10
ip route add table vpn default dev tun0
EOF

    cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute
    chmod +x /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute
}

add_mark() {
    grep -q "99 vpn" /etc/iproute2/rt_tables || echo '99 vpn' >> /etc/iproute2/rt_tables
    
    if ! uci show network | grep -q mark0x1; then
        printf "\033[32;1mConfigure mark rule\033[0m\n"
        uci add network rule
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit network
    fi
}

add_tunnel() {
    TUNNEL=singbox
    printf "\033[32;1mAutomatically configuring Sing-box...\033[0m\n"

    if opkg list-installed | grep -q sing-box; then
        echo "Sing-box already installed"
    else
        AVAILABLE_SPACE=$(df / | awk 'NR>1 { print $4 }')
        if [[ "$AVAILABLE_SPACE" -gt 2000 ]]; then
            echo "Installing sing-box..."
            opkg install sing-box
        else
            printf "\033[31;1mNot enough free space for sing-box. Installation aborted.\033[0m\n"
            exit 1
        fi
    fi

    # Ensure sing-box is enabled and runs as root
    if ! grep -q "option enabled '1'" /etc/config/sing-box; then
        sed -i "s/option enabled '0'/option enabled '1'/" /etc/config/sing-box 2>/dev/null || true
    fi
    if ! grep -q "option user 'root'" /etc/config/sing-box; then
        sed -i "s/option user 'sing-box'/option user 'root'/" /etc/config/sing-box 2>/dev/null || true
    fi

    # Create default config if missing
    if [ ! -f /etc/sing-box/config.json ] || ! grep -q "tun0" /etc/sing-box/config.json; then
cat << 'EOF' > /etc/sing-box/config.json
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "tun",
      "interface_name": "tun0",
      "domain_strategy": "ipv4_only",
      "address": ["172.16.250.1/30"],
      "auto_route": false,
      "strict_route": false,
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "server": "example.com",
      "server_port": 443,
      "method": "2022-blake3-aes-128-gcm",
      "password": "your-password-here"
    }
  ],
  "route": {
    "auto_detect_interface": true
  }
}
EOF
        printf "\033[33;1m⚠️  Default Sing-box config created at /etc/sing-box/config.json. Edit it manually!\033[0m\n"
        printf "\033[32;1mOfficial docs: https://sing-box.sagernet.org/configuration/outbound/\033[0m\n"
    fi

    route_vpn
}

add_zone() {
    TUNNEL=singbox
    if uci show firewall | grep -q "@zone.*name='singbox'"; then
        printf "\033[32;1mZone already exists\033[0m\n"
    else
        printf "\033[32;1mCreating firewall zone for singbox...\033[0m\n"

        # Clean up any old tun0 zones
        zone_id=$(uci show firewall | grep -E '@zone\[[0-9]+\]\.device.*tun0' | head -n1 | cut -d'[' -f2 | cut -d']' -f1)
        if [ -n "$zone_id" ]; then
            uci delete firewall.@zone[$zone_id]
        fi

        uci add firewall zone
        uci set firewall.@zone[-1].name='singbox'
        uci set firewall.@zone[-1].device='tun0'
        uci set firewall.@zone[-1].forward='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    fi

    if uci show firewall | grep -q "@forwarding.*name='singbox-lan'"; then
        printf "\033[32;1mForwarding already configured\033[0m\n"
    else
        printf "\033[32;1mConfiguring forwarding from LAN to singbox...\033[0m\n"
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].name='singbox-lan'
        uci set firewall.@forwarding[-1].dest='singbox'
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    fi
}

add_set() {
    if uci show firewall | grep -q "@ipset.*name='vpn_domains'"; then
        printf "\033[32;1mIP set already exists\033[0m\n"
    else
        printf "\033[32;1mCreating IP set for domains...\033[0m\n"
        uci add firewall ipset
        uci set firewall.@ipset[-1].name='vpn_domains'
        uci set firewall.@ipset[-1].match='dst_net'
        uci commit firewall
    fi

    if uci show firewall | grep -q "@rule.*name='mark_domains'"; then
        printf "\033[32;1mMark rule already exists\033[0m\n"
    else
        printf "\033[32;1mCreating mark rule for domains...\033[0m\n"
        uci add firewall rule
        uci set firewall.@rule[-1].name='mark_domains'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='*'
        uci set firewall.@rule[-1].proto='all'
        uci set firewall.@rule[-1].ipset='vpn_domains'
        uci set firewall.@rule[-1].set_mark='0x1'
        uci set firewall.@rule[-1].target='MARK'
        uci set firewall.@rule[-1].family='ipv4'
        uci commit firewall
    fi
}

dnsmasqfull() {
    if opkg list-installed | grep -q dnsmasq-full; then
        printf "\033[32;1mdnsmasq-full already installed\033[0m\n"
    else
        printf "\033[32;1mInstalling dnsmasq-full...\033[0m\n"
        cd /tmp/ && opkg download dnsmasq-full
        opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/
        [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
    fi
}

dnsmasqconfdir() {
    if [ $VERSION_ID -ge 24 ]; then
        if ! uci get dhcp.@dnsmasq[0].confdir 2>/dev/null | grep -q '/tmp/dnsmasq.d'; then
            printf "\033[32;1mSetting dnsmasq confdir...\033[0m\n"
            uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
            uci commit dhcp
        fi
    fi
}

add_dns_resolver() {
    printf "\033[32;1mInstalling and configuring DNSCrypt2...\033[0m\n"

    if opkg list-installed | grep -q dnscrypt-proxy2; then
        printf "\033[32;1mDNSCrypt2 already installed\033[0m\n"
    else
        opkg install dnscrypt-proxy2
        if grep -q "# server_names" /etc/dnscrypt-proxy2/dnscrypt-proxy.toml; then
            sed -i "s/^# server_names =.*/server_names = ['google', 'cloudflare', 'scaleway-fr', 'yandex']/g" /etc/dnscrypt-proxy2/dnscrypt-proxy.toml
        fi
    fi

    # Configure dnsmasq to use DNSCrypt
    uci set dhcp.@dnsmasq[0].noresolv="1"
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server="127.0.0.53#53"
    uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
    uci commit dhcp

    printf "\033[32;1mRestarting DNSCrypt...\033[0m\n"
    /etc/init.d/dnscrypt-proxy restart
    sleep 10

    printf "\033[32;1mRestarting dnsmasq...\033[0m\n"
    /etc/init.d/dnsmasq restart
}

add_getdomains() {
    printf "\033[32;1mCreating getdomains script for Russia (inside)...\033[0m\n"

    cat << 'EOF' > /etc/init.d/getdomains
#!/bin/sh /etc/rc.common

START=99

start () {
    DOMAINS=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst
    count=0
    while true; do
        if curl -m 3 github.com; then
            curl -f "$DOMAINS" --output /tmp/dnsmasq.d/domains.lst
            break
        else
            echo "GitHub is not available. Check internet [$count]"
            count=$((count+1))
            sleep 5
        fi
    done

    if dnsmasq --conf-file=/tmp/dnsmasq.d/domains.lst --test 2>&1 | grep -q "syntax check OK"; then
        /etc/init.d/dnsmasq restart
    fi
}
EOF

    chmod +x /etc/init.d/getdomains
    /etc/init.d/getdomains enable

    if ! crontab -l | grep -q "/etc/init.d/getdomains"; then
        crontab -l 2>/dev/null | { cat; echo "0 */8 * * * /etc/init.d/getdomains start"; } | crontab -
        /etc/init.d/cron restart 2>/dev/null || true
    fi

    /etc/init.d/getdomains start
}

add_packages() {
    if opkg list-installed | grep -q "^curl "; then
        printf "\033[32;1mcurl already installed\033[0m\n"
    else
        printf "\033[32;1mInstalling curl...\033[0m\n"
        opkg install curl
    fi
}

# System Details
MODEL=$(cat /tmp/sysinfo/model)
source /etc/os-release
printf "\033[34;1mModel: $MODEL\033[0m\n"
printf "\033[34;1mVersion: $OPENWRT_RELEASE\033[0m\n"

VERSION_ID=$(echo $VERSION | awk -F. '{print $1}')

if [ "$VERSION_ID" -ne 23 ] && [ "$VERSION_ID" -ne 24 ]; then
    printf "\033[31;1mScript only supports OpenWrt 23.05 and 24.10\033[0m\n"
    exit 1
fi

printf "\033[31;1mAll actions performed here cannot be rolled back automatically.\033[0m\n"

setup_singbox_auto_update() {
    printf "\033[32;1mНастройка автоматического обновления конфигурации sing-box...\033[0m\n"

    while true; do
        read -r -p "Введите ссылку на конфиг (пример: https://link.example.ru:8888/JpxXh1o67VQStfg_): " USER_LINK

        # Очистка от пробелов
        USER_LINK="$(echo "$USER_LINK" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        # Проверка формата и валидности порта
        if echo "$USER_LINK" | grep -qE '^https://[^:/]+:[0-9]{1,5}/[^/]+$'; then
            PORT=$(echo "$USER_LINK" | sed -n 's/.*:\([0-9]\{1,5\}\)\/.*/\1/p')
            if [ -n "$PORT" ] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] 2>/dev/null; then
                break
            fi
        fi
        echo "Некорректный формат. Пример: https://link.example.ru:8888/JpxXh1o67VQStfg_"
    done

    BASE_URL="${USER_LINK%/*}"
    TOKEN="${USER_LINK##*/}"
    CONFIG_URL="$USER_LINK"
    HASH_URL="$BASE_URL/hash/$TOKEN"

    # Скачиваем шаблон
    UPDATE_SCRIPT_URL="https://raw.githubusercontent.com/Dead365-dev/sing-box-installer/master/singbox-update.sh"
    TARGET_SCRIPT="/etc/singbox-update.sh"

    if ! wget -q -O "$TARGET_SCRIPT" "$UPDATE_SCRIPT_URL"; then
        printf "\033[31;1mНе удалось скачать скрипт обновления.\033[0m\n"
        return 1
    fi

    # Экранируем для sed
    ESC_CONFIG=$(printf '%s\n' "$CONFIG_URL" | sed 's/[^^]/[&]/g; s/\^/\\^/g')
    ESC_HASH=$(printf '%s\n' "$HASH_URL" | sed 's/[^^]/[&]/g; s/\^/\\^/g')

    # Подставляем значения
    sed -i "s|CONFIG_URL=.*|CONFIG_URL=\"$CONFIG_URL\"|" "$TARGET_SCRIPT"
    sed -i "s|HASH_URL=.*|HASH_URL=\"$HASH_URL\"|" "$TARGET_SCRIPT"
    # sed -i "s|LOCAL_CONFIG=.*|LOCAL_CONFIG=\"/etc/sing-box/config.json\"|" "$TARGET_SCRIPT"
    # sed -i "s|SERVICE_NAME=.*|SERVICE_NAME=\"sing-box\"|" "$TARGET_SCRIPT"


    # Адаптация под OpenWrt (без systemd)
    sed -i 's|service "$SERVICE_NAME" restart|/etc/init.d/sing-box restart|g' "$TARGET_SCRIPT"

    # Удаляем проверку на 'service'
    sed -i '/for cmd in curl jq sha256sum service; do/,+4d' "$TARGET_SCRIPT"
    sed -i '/^# === Проверка наличия зависимостей ===$/,/^done$/d' "$TARGET_SCRIPT"

    # Вставляем совместимую проверку
    sed -i "1i# === Проверка зависимостей (OpenWrt) ===\nfor cmd in curl jq sha256sum; do\n  if ! command -v \"\$cmd\" >/dev/null 2>&1; then\n    error \"Не установлена зависимость: \$cmd\"\n    exit 1\n  fi\ndone\n" "$TARGET_SCRIPT"

    chmod +x "$TARGET_SCRIPT"

    # Добавляем в cron (раз в час)
    if ! crontab -l 2>/dev/null | grep -q "singbox-update"; then
        crontab -l 2>/dev/null | { cat; echo "0 * * * * /etc/singbox-update.sh >> /var/log/singbox-update.log 2>&1"; } | crontab -
        /etc/init.d/cron restart 2>/dev/null || true
    fi

    printf "\033[32;1mАвтообновление настроено!\033[0m\n"
    printf "CONFIG_URL: %s\n" "$CONFIG_URL"
    printf "HASH_URL:   %s\n" "$HASH_URL"
    printf "Скрипт:     %s\n" "$TARGET_SCRIPT"
}

check_repo

add_packages

add_tunnel

add_mark

add_zone

add_set

dnsmasqfull

dnsmasqconfdir

add_dns_resolver

add_getdomains

setup_singbox_auto_update

printf "\033[32;1mRestarting network...\033[0m\n"
/etc/init.d/network restart

printf "\033[32;1m✅ Всё готово!\033[0m\n"