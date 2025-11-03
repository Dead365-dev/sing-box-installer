#!/bin/sh

# === Настройки (будут заменены установочным скриптом) ===
CONFIG_URL="https://example.com/sing-box.json"
HASH_URL="https://example.com/hash/JpxXh1o67VQStSk_"
LOCAL_CONFIG="/etc/sing-box/config.json"
TMP_CONFIG="/tmp/sing-box-new.json"
SERVICE_NAME="sing-box"

# === Вспомогательные функции ===
log() {
    echo "$(date '+%F %T') [INFO] $*"
}

error() {
    echo "$(date '+%F %T') [ERROR] $*" >&2
    exit 1
}

# === Проверка зависимостей ===
for cmd in curl jq sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Не установлена зависимость: $cmd"
    fi
done

# === Если локальный конфиг отсутствует — загружаем впервые ===
if [ ! -f "$LOCAL_CONFIG" ]; then
    log "Локальный конфиг не найден. Загружаем с сервера..."
    if curl -fsSL "$CONFIG_URL" -o "$LOCAL_CONFIG"; then
        if jq empty "$LOCAL_CONFIG" >/dev/null 2>&1; then
            log "Конфиг успешно загружен и валиден. Перезапускаем $SERVICE_NAME..."
            if /etc/init.d/sing-box restart; then
                log "Сервис успешно перезапущен."
            else
                error "Не удалось перезапустить $SERVICE_NAME"
            fi
        else
            error "Загруженный конфиг невалиден. Удаляем."
            rm -f "$LOCAL_CONFIG"
        fi
    else
        error "Не удалось скачать конфиг с $CONFIG_URL"
    fi
    exit 0
fi

# === Получаем удалённый хэш ===
remote_hash_json=$(curl -fsSL "$HASH_URL")
if [ -z "$remote_hash_json" ]; then
    error "Пустой ответ от $HASH_URL"
fi

REMOTE_HASH=$(echo "$remote_hash_json" | jq -r '.sha256' 2>/dev/null)
if [ -z "$REMOTE_HASH" ] || [ "$REMOTE_HASH" = "null" ]; then
    error "Не удалось извлечь sha256 из ответа $HASH_URL"
fi

# === Считаем локальный хэш ===
LOCAL_HASH=$(sha256sum "$LOCAL_CONFIG" 2>/dev/null | awk '{print $1}')
if [ -z "$LOCAL_HASH" ]; then
    error "Не удалось вычислить хэш локального файла"
fi

# === Сравнение хэшей ===
if [ "$REMOTE_HASH" = "$LOCAL_HASH" ]; then
    log "Хэш не изменился. Конфиг актуален."
    exit 0
fi

# === Хэш изменился — скачиваем новый конфиг ===
log "Хэш изменился. Загружаем новый конфиг..."

if ! curl -fsSL "$CONFIG_URL" -o "$TMP_CONFIG"; then
    error "Не удалось скачать новый конфиг с $CONFIG_URL"
fi

if [ ! -s "$TMP_CONFIG" ]; then
    error "Новый конфиг пустой. Пропускаем обновление."
    rm -f "$TMP_CONFIG"
    exit 1
fi

if ! jq empty "$TMP_CONFIG" >/dev/null 2>&1; then
    error "Новый конфиг содержит ошибку JSON. Пропускаем обновление."
    rm -f "$TMP_CONFIG"
    exit 1
fi

# === Создаём резервную копию ===
BACKUP="${LOCAL_CONFIG}.bak_$(date +%Y%m%d_%H%M%S)"
if ! cp "$LOCAL_CONFIG" "$BACKUP"; then
    error "Не удалось создать резервную копию"
fi
log "Создана резервная копия: $BACKUP"

# === Заменяем конфиг ===
if ! mv "$TMP_CONFIG" "$LOCAL_CONFIG"; then
    error "Не удалось заменить конфиг"
fi

# === Перезапуск сервиса ===
if /etc/init.d/sing-box restart; then
    log "Конфиг обновлён и сервис $SERVICE_NAME успешно перезапущен."
else
    log "Ошибка при перезапуске $SERVICE_NAME. Восстанавливаем старый конфиг..."
    if cp "$BACKUP" "$LOCAL_CONFIG" && /etc/init.d/sing-box restart; then
        log "Восстановление прошло успешно."
    else
        error "Критическая ошибка: не удалось восстановить конфиг и перезапустить сервис."
    fi
fi