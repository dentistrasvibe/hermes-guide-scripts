#!/usr/bin/env bash
# ============================================================================
# setup-hermes-web.sh
# ----------------------------------------------------------------------------
# Поднимает веб-интерфейс Hermes Agent с HTTPS и паролем — по умолчанию через
# бесплатный sslip.io (без покупки домена), либо на твоём собственном домене.
# Запускается ПОСЛЕ установки Hermes (глава 2.1) — под root.
#
# Что делает:
#   1. Ставит nginx, certbot и утилиту для паролей
#   2. Делает web-интерфейс (hermes dashboard) постоянным сервисом
#      на 127.0.0.1:9119 — наружу он сам по себе не смотрит
#   3. Настраивает nginx как «ресепшн»: принимает гостей из интернета
#      по адресу sslip.io (или твоему домену) и проводит их к dashboard внутри
#   4. Закрывает вход логином и паролем (Basic Auth)
#   5. Вешает бесплатный SSL-сертификат Let's Encrypt (https + авто-продление)
#
# По умолчанию использует адрес вида <ip-сервера>.sslip.io — sslip.io это
# бесплатный DNS-сервис, который превращает любой IP в домен. Ничего
# регистрировать и ждать не надо. Если хочешь свой домен — введи его на запрос.
#
# Спросит: адрес (или Enter для авто-sslip.io), логин, пароль, e-mail.
#
# Использование (под root):
#   curl -fsSL https://<твой-хост>/setup-hermes-web.sh | bash
#
# Прочитать перед запуском:
#   curl -fsSL https://<твой-хост>/setup-hermes-web.sh | less
# ============================================================================

set -eu

# --- Цвета ------------------------------------------------------------------
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

# Ввод читаем из /dev/tty, чтобы работало даже при запуске через `curl | bash`
# (там обычный stdin занят телом скрипта).
TTY="/dev/tty"
ask() {  # ask "Вопрос: " VARNAME
  local prompt="$1" __var="$2" __val=""
  printf '%s' "$prompt" > "$TTY"
  IFS= read -r __val < "$TTY"
  printf -v "$__var" '%s' "$__val"
}
ask_secret() {  # ask_secret "Вопрос: " VARNAME
  local prompt="$1" __var="$2" __val=""
  printf '%s' "$prompt" > "$TTY"
  IFS= read -rs __val < "$TTY"
  printf '\n' > "$TTY"
  printf -v "$__var" '%s' "$__val"
}

# --- Предварительные проверки -----------------------------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  err "Этот скрипт должен запускаться от имени root."
  err "Зайди по SSH как root (или выполни: sudo bash $0)."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  err "Скрипт работает только на Debian/Ubuntu (apt-get не найден)."
  exit 1
fi

# Проверка /dev/tty перенесена ниже — она нужна только если хоть один ответ
# придётся спрашивать у человека. В не-интерактивном режиме (все значения
# переданы через переменные окружения оркестратором) терминал не требуется.

# Hermes должен быть уже установлен под пользователем hermes (глава 2.1)
if ! id hermes >/dev/null 2>&1; then
  err "Пользователь hermes не найден. Сначала пройди главу 2.1 (установка Hermes)."
  exit 1
fi

HERMES_BIN="/home/hermes/.local/bin/hermes"
if [ ! -x "$HERMES_BIN" ]; then
  # запасной поиск, если установщик положил бинарник в другое место
  HERMES_BIN="$(su - hermes -c 'command -v hermes' 2>/dev/null || true)"
fi
if [ -z "${HERMES_BIN:-}" ] || [ ! -x "$HERMES_BIN" ]; then
  err "Не нашёл команду hermes у пользователя hermes."
  err "Убедись, что установка из главы 2.1 завершилась (и сделан 'source ~/.bashrc')."
  exit 1
fi

DASH_HOST="127.0.0.1"
DASH_PORT="9119"

echo "${BOLD}Hermes Agent — веб-интерфейс${RESET}"
echo "Бинарник hermes: ${HERMES_BIN}"

# --- Определяем публичный IP сервера для авто-адреса через sslip.io ---------
SERVER_IP="$(curl -fsS https://api.ipify.org 2>/dev/null || true)"
if [ -z "${SERVER_IP:-}" ]; then
  SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
# Авто-адрес через sslip.io работает только если SERVER_IP — публичный.
# На NAT/приватных IP такой адрес снаружи не зарезолвится.
case "${SERVER_IP:-}" in
  10.*|192.168.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.3[01].*|127.*|"")
    AUTO_DOMAIN=""
    ;;
  *)
    AUTO_DOMAIN="$(echo "$SERVER_IP" | tr '.' '-').sslip.io"
    ;;
esac

# --- Опрос пользователя -----------------------------------------------------
# Значения берём в приоритете: позиционный аргумент -> переменная окружения ->
# интерактивный вопрос. Оркестратор install-hermes-unattended.sh передаёт всё
# через окружение (DOMAIN, PANEL_USER, PANEL_PASS, EMAIL), поэтому в его случае
# ни одного вопроса не задаётся.
DOMAIN="${1:-${DOMAIN:-}}"
LOGIN="${2:-${PANEL_USER:-}}"
PASSWORD="${PANEL_PASS:-}"
EMAIL="${EMAIL:-}"
USING_AUTO_DOMAIN=""

# Не-интерактивный режим: всё, что иначе пришлось бы спрашивать, уже задано.
NONINTERACTIVE=""
if [ -n "${DOMAIN:-}" ] && [ -n "${LOGIN:-}" ] && [ -n "${PASSWORD:-}" ]; then
  NONINTERACTIVE="yes"
fi

# Терминал нужен только в интерактивном режиме.
if [ -z "$NONINTERACTIVE" ] && [ ! -e "$TTY" ]; then
  err "Нет доступа к терминалу (/dev/tty) — скрипту нужно задать тебе вопросы."
  err "Либо задай DOMAIN, PANEL_USER, PANEL_PASS, EMAIL через окружение,"
  err "либо скачай скрипт и запусти из файла:"
  err "  curl -fsSL <URL> -o setup-hermes-web.sh && bash setup-hermes-web.sh"
  exit 1
fi

if [ -z "${DOMAIN:-}" ]; then
  echo
  if [ -n "${AUTO_DOMAIN:-}" ]; then
    echo "  Адрес веб-интерфейса. По умолчанию используется бесплатный сервис sslip.io —"
    echo "  он превращает IP сервера в адрес с поддержкой SSL, ничего покупать и"
    echo "  ждать не надо."
    echo
    echo "      По умолчанию:  ${BOLD}${AUTO_DOMAIN}${RESET}"
    echo
    ask "  Enter для авто-адреса, или введи свой домен: " DOMAIN
    if [ -z "${DOMAIN:-}" ]; then
      DOMAIN="$AUTO_DOMAIN"
      USING_AUTO_DOMAIN="yes"
    fi
  else
    warn "Не удалось определить публичный IP — авто-адрес через sslip.io недоступен."
    warn "Введи свой домен (его A-запись должна указывать на этот сервер)."
    while [ -z "${DOMAIN:-}" ]; do
      ask "Домен: " DOMAIN
    done
  fi
fi
# Если пользователь ввёл вручную тот же sslip.io-адрес — тоже считаем авто
if [ -n "${AUTO_DOMAIN:-}" ] && [ "$DOMAIN" = "$AUTO_DOMAIN" ]; then
  USING_AUTO_DOMAIN="yes"
fi

while [ -z "${LOGIN:-}" ]; do
  ask "Логин для входа в веб-интерфейс: " LOGIN
done

if [ -z "$NONINTERACTIVE" ]; then
  PASSWORD2=""
  while : ; do
    ask_secret "Пароль для входа: " PASSWORD
    ask_secret "Повтори пароль:   " PASSWORD2
    if [ -z "$PASSWORD" ]; then
      warn "Пароль не может быть пустым, попробуй ещё раз."
    elif [ "$PASSWORD" != "$PASSWORD2" ]; then
      warn "Пароли не совпали, попробуй ещё раз."
    else
      break
    fi
  done

  ask "E-mail для уведомлений Let's Encrypt (можно оставить пустым): " EMAIL
fi

echo
echo "  Домен:  ${BOLD}${DOMAIN}${RESET}"
echo "  Логин:  ${BOLD}${LOGIN}${RESET}"
echo "  SSL:    Let's Encrypt${EMAIL:+ (}${EMAIL}${EMAIL:+)}"

# --- 1/5. Установка nginx, certbot, утилит ----------------------------------
step "1/5. Ставлю nginx, certbot и утилиты..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx apache2-utils
ok "nginx и certbot установлены."

# --- 2/5. Постоянный сервис для web-интерфейса ------------------------------
step "2/5. Делаю web-интерфейс постоянным сервисом..."

# Системный сервис, но процесс работает ОТ ИМЕНИ hermes (не root).
# --tui        — включает вкладку чата прямо в браузере (через WebSocket)
# --skip-build — отдаёт уже собранный интерфейс (его собрал 'hermes update' в 2.1),
#                чтобы сервису не требовался npm при старте
# host 127.0.0.1 — слушает только локально; наружу смотрит только nginx
cat > /etc/systemd/system/hermes-dashboard.service <<EOF
[Unit]
Description=Hermes Agent Web Dashboard
After=network.target

[Service]
Type=simple
User=hermes
Group=hermes
Environment=HOME=/home/hermes
ExecStart=${HERMES_BIN} dashboard --no-open --host ${DASH_HOST} --port ${DASH_PORT} --tui --skip-build
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hermes-dashboard >/dev/null 2>&1
systemctl restart hermes-dashboard
ok "Сервис hermes-dashboard запущен."

# Ждём, пока интерфейс реально начнёт отвечать на 127.0.0.1:9119
step "   Жду, пока web-интерфейс поднимется..."
UP=""
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://${DASH_HOST}:${DASH_PORT}" 2>/dev/null; then
    UP="yes"; break
  fi
  # 200/401/403/любой ответ = порт уже слушает; ловим даже не-2xx
  if curl -sS -o /dev/null "http://${DASH_HOST}:${DASH_PORT}" 2>/dev/null; then
    UP="yes"; break
  fi
  sleep 1
done
if [ -n "$UP" ]; then
  ok "Web-интерфейс отвечает на 127.0.0.1:${DASH_PORT}."
else
  warn "Web-интерфейс пока не отвечает. Проверь логи:"
  warn "  journalctl -u hermes-dashboard -n 50 --no-pager"
fi

# --- 3/5. Логин и пароль (Basic Auth) ---------------------------------------
step "3/5. Создаю файл с логином и паролем..."
HTPASSWD_FILE="/etc/nginx/.htpasswd-hermes"
printf '%s' "$PASSWORD" | htpasswd -ci "$HTPASSWD_FILE" "$LOGIN"
chmod 640 "$HTPASSWD_FILE"
chown root:www-data "$HTPASSWD_FILE" 2>/dev/null || true
ok "Доступ закрыт логином '${LOGIN}'."

# --- 4/5. Конфиг nginx ------------------------------------------------------
step "4/5. Настраиваю nginx..."
SITE="/etc/nginx/sites-available/hermes"
cat > "$SITE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    # Служебный путь Let's Encrypt — без пароля, иначе certbot не подтвердит домен
    location /.well-known/acme-challenge/ {
        auth_basic off;
        allow all;
        root /var/www/html;
    }

    location / {
        auth_basic "Hermes Agent";
        auth_basic_user_file ${HTPASSWD_FILE};

        proxy_pass http://${DASH_HOST}:${DASH_PORT};
        proxy_http_version 1.1;

        # WebSocket — нужен для живого потока ответов и вкладки чата (--tui)
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Hermes-dashboard проверяет заголовок Host и пускает только тот адрес,
        # на который сам забиндился (127.0.0.1). Иначе — "Invalid Host header".
        proxy_set_header Host ${DASH_HOST};

        # чтобы простаивающий чат не отваливался по таймауту
        proxy_read_timeout 86400;
    }
}
EOF

ln -sf "$SITE" /etc/nginx/sites-enabled/hermes
# дефолтный сайт убираем, чтобы он не перехватывал запросы
rm -f /etc/nginx/sites-enabled/default

if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx
  ok "nginx настроен (пока по http)."
else
  err "Ошибка в конфиге nginx:"
  nginx -t || true
  exit 1
fi

# --- 5/5. SSL через Let's Encrypt -------------------------------------------
step "5/5. Получаю SSL-сертификат (Let's Encrypt)..."

CERTBOT_EMAIL_ARG="--register-unsafely-without-email"
[ -n "${EMAIL:-}" ] && CERTBOT_EMAIL_ARG="-m ${EMAIL}"
CERTBOT_CMD="certbot --nginx -d ${DOMAIN} --agree-tos -n --redirect ${CERTBOT_EMAIL_ARG}"

# Понятный разбор для новичка: что не так с доменом и как починить.
# Используется только в ветке «свой домен», авто-sslip.io этой проблемы не имеет.
DOMAIN_IP=""
dns_help() {
  echo
  echo "  ${BOLD}Похоже, домен ещё не привязан к этому серверу.${RESET}"
  echo
  echo "    • IP этого сервера:           ${BOLD}${SERVER_IP:-не удалось определить}${RESET}"
  if [ -n "${DOMAIN_IP:-}" ]; then
    echo "    • ${DOMAIN} сейчас ведёт на:  ${BOLD}${DOMAIN_IP}${RESET}"
  else
    echo "    • ${DOMAIN} сейчас ведёт на:  ${BOLD}никуда (A-запись не найдена)${RESET}"
  fi
  echo
  echo "  ${BOLD}Что сделать${RESET} (это шаг про A-запись из гайда):"
  echo "    1. Зайди в панель регистратора (там, где покупал домен)."
  echo "    2. В DNS-настройках создай запись типа ${BOLD}A${RESET}:"
  echo "         тип:      A"
  echo "         имя/host: ${BOLD}${DOMAIN}${RESET}  (или только поддомен — часть слева)"
  echo "         значение: ${BOLD}${SERVER_IP:-IP-твоего-сервера}${RESET}"
  echo "    3. Сохрани и подожди 5–30 минут — DNS обновляется не сразу."
  echo
  echo "  ${BOLD}Частые ошибки:${RESET} опечатка в IP; запись создана для другого поддомена;"
  echo "  включён прокси Cloudflare (оранжевое облако) — для выпуска сертификата"
  echo "  временно переключи на серое облако (DNS only)."
  echo
  echo "  ${BOLD}Подсказка:${RESET} если возиться с доменом не хочется, перезапусти скрипт и"
  echo "  на вопрос про адрес нажми Enter — он использует бесплатный sslip.io."
  echo
}

# Решаем, идти ли в certbot
PROCEED_SSL="yes"
if [ -n "${USING_AUTO_DOMAIN:-}" ]; then
  # sslip.io резолвится в нужный IP по конструкции — DNS-проверку пропускаем
  ok "Адрес ${DOMAIN} (sslip.io автоматически указывает на ${SERVER_IP})."
else
  # Свой домен — сверяем, что A-запись смотрит на этот сервер
  DOMAIN_IP="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1)"
  if [ -z "${DOMAIN_IP:-}" ]; then
    err "Домен ${DOMAIN} пока никуда не указывает — A-запись не найдена."
    dns_help
    PROCEED_SSL=""
  elif [ -n "${SERVER_IP:-}" ] && [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
    warn "Домен ${DOMAIN} указывает на ${DOMAIN_IP}, а этот сервер — ${SERVER_IP}."
    dns_help
    ANSWER=""
    ask "Всё равно попробовать выпустить сертификат? (для прокси Cloudflare — да) [y/N]: " ANSWER
    case "${ANSWER:-}" in
      y|Y|yes|Yes|да|Да) PROCEED_SSL="yes" ;;
      *) PROCEED_SSL="" ;;
    esac
  else
    ok "Домен ${DOMAIN} указывает на этот сервер (${SERVER_IP})."
  fi
fi

SSL_OK=""
if [ -n "$PROCEED_SSL" ]; then
  if $CERTBOT_CMD; then
    SSL_OK="yes"
    ok "Сертификат получен, https включён, авто-продление настроено."
  else
    err "Certbot не смог выпустить сертификат."
    dns_help
    echo "  Когда поправишь A-запись и она разойдётся — выпусти сертификат одной"
    echo "  командой (заново весь скрипт гонять НЕ нужно):"
    echo
    echo "      ${BOLD}${CERTBOT_CMD}${RESET}"
    echo
  fi
else
  warn "Пропускаю выпуск SSL — сначала привяжи домен (инструкция выше)."
  warn "Сайт уже работает по http. Когда A-запись будет готова, выполни:"
  echo
  echo "      ${BOLD}${CERTBOT_CMD}${RESET}"
  echo
fi

# --- Финал ------------------------------------------------------------------
SCHEME="http"
[ -n "$SSL_OK" ] && SCHEME="https"

# Гайдовая плашка только для ручного запуска. В авто-установщике
# (HERMES_UNATTENDED=1) её глушим — orchestrator отдаёт свою ::done:: карточку.
# SSL-предупреждение оставляем всегда: это диагностика, а не указатель в гайд.
if [ -z "${HERMES_UNATTENDED:-}" ]; then
cat <<EOF

${GREEN}${BOLD}════════════════════════════════════════════════════════════════════${RESET}
${GREEN}${BOLD}  ✓ Веб-интерфейс Hermes готов${RESET}
${GREEN}${BOLD}════════════════════════════════════════════════════════════════════${RESET}

  Открой в браузере:   ${BOLD}${SCHEME}://${DOMAIN}${RESET}
  Логин:               ${BOLD}${LOGIN}${RESET}
  Пароль:              ${BOLD}(тот, что ты ввёл выше)${RESET}

EOF
fi

if [ -z "$SSL_OK" ]; then
  echo "  ${YELLOW}${BOLD}SSL пока не выпущен — сайт работает по http.${RESET}"
  [ -z "${HERMES_UNATTENDED:-}" ] && echo "  ${YELLOW}Поправь DNS и перезапусти certbot (команда выше).${RESET}"
  echo
fi

if [ -z "${HERMES_UNATTENDED:-}" ]; then
cat <<EOF
${GREEN}${BOLD}────────────────────────────────────────────────────────────────────${RESET}

  Дальше — вернись в гайд: войди в интерфейс и подключи ИИ-провайдера.

${GREEN}${BOLD}════════════════════════════════════════════════════════════════════${RESET}

EOF
fi
