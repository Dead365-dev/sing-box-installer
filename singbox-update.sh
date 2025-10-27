#!/bin/bash

# === Настройки ===
CONFIG_URL="https://example.com/sing-box.json"       # URL откуда брать конфиг
HASH_URL="https://example.com/hash/JpxXh1o67VQStSk_" # URL, который возвращает sha256 в JSON
LOCAL_CONFIG="/etc/sing-box/config.json"              # Текущий конфиг
TMP_CONFIG="/tmp/sing-box-new.json"                   # Временный файл
SERVICE_NAME="sing-box"                               # Имя systemd-сервиса

# === Функция для логов ===
log() {
  echo "$(date '+%F %T') [INFO] $*"
}

error() {
  echo "$(date '+%F %T') [ERROR] $*" >&2
}

# === Проверка наличия зависимостей ===
for cmd in curl jq sha256sum service; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "Не установлена зависимость: $cmd"
    exit 1
  fi
done

# === Если локальный конфиг отсутствует ===
if [ ! -f "$LOCAL_CONFIG" ]; then
  log "Локальный конфиг не найден. Загружаем с сервера..."
  if curl -fsSL "$CONFIG_URL" -o "$LOCAL_CONFIG"; then
    if jq empty "$LOCAL_CONFIG" >/dev/null 2>&1; then
      log "Конфиг успешно загружен и валиден. Перезапускаем $SERVICE_NAME..."
      service "$SERVICE_NAME" restart && log "Сервис успешно перезапущен."
    else
      error "Загруженный конфиг невалиден. Удаляем."
      rm -f "$LOCAL_CONFIG"
      exit 1
    fi
  else
    error "Не удалось скачать конфиг с $CONFIG_URL"
    exit 1
  fi
  exit 0
fi

# === Получаем удалённый хэш ===
REMOTE_HASH=$(curl -fsSL "$HASH_URL" | jq -r '.sha256')
if [ -z "$REMOTE_HASH" ] || [ "$REMOTE_HASH" == "null" ]; then
  error "Не удалось получить sha256 с $HASH_URL"
  exit 1
fi

# === Считаем локальный хэш ===
LOCAL_HASH=$(sha256sum "$LOCAL_CONFIG" | awk '{print $1}')

# === Если хэш не изменился ===
if [ "$REMOTE_HASH" == "$LOCAL_HASH" ]; then
  log "Хэш не изменился. Конфиг актуален."
  exit 0
fi

# === Иначе — скачиваем новый конфиг ===
log "Хэш изменился. Загружаем новый конфиг..."

if ! curl -fsSL "$CONFIG_URL" -o "$TMP_CONFIG"; then
  error "Не удалось скачать новый конфиг с $CONFIG_URL"
  exit 1
fi

# === Проверка валидности JSON ===
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

# === Обновление конфига ===
BACKUP="${LOCAL_CONFIG}.bak_$(date +%Y%m%d_%H%M%S)"
cp "$LOCAL_CONFIG" "$BACKUP" && log "Создана резервная копия: $BACKUP"

mv "$TMP_CONFIG" "$LOCAL_CONFIG"

# === Перезапуск сервиса ===
if service "$SERVICE_NAME" restart; then
  log "Конфиг обновлён и сервис $SERVICE_NAME успешно перезапущен."
else
  error "Ошибка при перезапуске $SERVICE_NAME. Восстанавливаем старый конфиг..."
  cp "$BACKUP" "$LOCAL_CONFIG"
  service "$SERVICE_NAME" restart
fi
