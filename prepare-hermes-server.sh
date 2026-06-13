set -eu

# --- Цвета (для приятного вывода) -------------------------------------------
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
fi

step() { echo; echo "${BLUE}${BOLD}==>${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo "  ${GREEN}✓${RESET} $1"; }
warn() { echo "  ${YELLOW}⚠${RESET} $1"; }
err()  { echo "  ${RED}✗${RESET} $1" >&2; }

# apt-get, но ждём блокировку пакетов до 5 минут вместо мгновенного падения.
# Свежесозданный VPS при первой загрузке сам запускает обновление (cloud-init /
# unattended-upgrades) и держит lock dpkg первые минуту-две — без ожидания наш
# самый первый вызов apt падает с "E: Could not get lock /var/lib/dpkg/lock-frontend".
apt_get() { apt-get -o Dpkg::Lock::Timeout=300 "$@"; }

# --- Предварительные проверки -----------------------------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  err "Этот скрипт должен запускаться от имени root."
  err "Попробуй:  sudo bash $0   или зайди по SSH как root."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  err "Скрипт работает только на Debian/Ubuntu (apt-get не найден)."
  exit 1
fi

OS_PRETTY=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown}")
echo "${BOLD}Hermes Agent — подготовка сервера${RESET}"
echo "Обнаружена ОС: ${OS_PRETTY}"

# --- 1/4. Обновление системы -------------------------------------------------
step "1/4. Обновляю систему (это займёт пару минут)..."
export DEBIAN_FRONTEND=noninteractive
apt_get update -qq
apt_get upgrade -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
ok "Система обновлена."

# --- 2/4. Установка зависимостей --------------------------------------------
step "2/4. Ставлю зависимости Hermes..."

# Основные runtime- и build-зависимости установщика Hermes
CORE_DEPS=(
  git              # установщик скачивает через него код агента
  xz-utils         # для распаковки встроенного Node.js (.tar.xz)
  ripgrep          # быстрый поиск по файлам — агент активно использует
  ffmpeg           # для голосовых сообщений в Telegram через TTS
  build-essential  # на случай компиляции Python-пакетов
  python3-dev      # заголовки Python для нативных модулей
  libffi-dev       # для cffi (используется частью Python-зависимостей)
  curl             # скачать установщик Hermes
  ca-certificates  # доверенные SSL-сертификаты для HTTPS
)

# Системные библиотеки для встроенного браузера Chromium (Playwright).
# Без них агент устанавливается, но веб-инструменты (открыть страницу,
# скриншот, скрейпинг) тихо ломаются.
PLAYWRIGHT_DEPS=(
  libnss3
  libnspr4
  libatk1.0-0
  libatk-bridge2.0-0
  libcups2
  libdbus-1-3
  libdrm2
  libxkbcommon0
  libxcomposite1
  libxdamage1
  libxfixes3
  libxrandr2
  libgbm1
  libxss1
)

# libasound переименован между Ubuntu 22.04 и 24.04 — выбираем правильный.
if apt-cache show libasound2t64 >/dev/null 2>&1; then
  PLAYWRIGHT_DEPS+=(libasound2t64)
else
  PLAYWRIGHT_DEPS+=(libasound2)
fi

apt_get install -y -qq "${CORE_DEPS[@]}" "${PLAYWRIGHT_DEPS[@]}"
ok "Все зависимости установлены."

# --- 3/4. Создание пользователя hermes --------------------------------------
step "3/4. Создаю выделенного пользователя hermes..."

HERMES_PASSWORD=""
if id hermes >/dev/null 2>&1; then
  warn "Пользователь hermes уже существует — пропускаю создание и смену пароля."
  HERMES_PASSWORD="(не изменён — пользователь уже существовал)"
else
  # 24-значный пароль из безопасного алфавита (без неоднозначных символов)
  HERMES_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=lI0O' | head -c 24)
  useradd -m -s /bin/bash hermes
  echo "hermes:${HERMES_PASSWORD}" | chpasswd
  ok "Пользователь hermes создан."
fi

# --- 4/4. Включение linger --------------------------------------------------
step "4/4. Включаю persistent-сервисы (linger) для hermes..."
loginctl enable-linger hermes
ok "Готово. Сервисы hermes будут жить даже когда ты не залогинен."

# --- Финал — пароль + указатель назад в гайд --------------------------------
# Гайдовая плашка только для ручного запуска (curl|bash). В авто-установщике
# (HERMES_UNATTENDED=1) её глушим — orchestrator сам отдаёт финальную карточку.
if [ -z "${HERMES_UNATTENDED:-}" ]; then
cat <<EOF

${GREEN}${BOLD}════════════════════════════════════════════════════════════════════${RESET}
${GREEN}${BOLD}  ✓ Сервер готов к установке Hermes Agent${RESET}
${GREEN}${BOLD}════════════════════════════════════════════════════════════════════${RESET}

  ${BOLD}Пароль пользователя hermes:${RESET}

      ${YELLOW}${BOLD}${HERMES_PASSWORD}${RESET}

  ${BOLD}СОХРАНИ ЭТОТ ПАРОЛЬ${RESET} в менеджер паролей прямо сейчас —
  он понадобится дальше.

${GREEN}${BOLD}────────────────────────────────────────────────────────────────────${RESET}

  Дальше — вернись в гайд и продолжи со следующего шага.

${GREEN}${BOLD}════════════════════════════════════════════════════════════════════${RESET}

EOF
else
  ok "Сервер готов (unattended)."
fi
