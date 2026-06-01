#!/usr/bin/env bash
# Pure helper functions for install-hermes-unattended.sh

# derive_panel_domain <domain> <public_ip>
# Empty domain -> "<dashed-ip>.sslip.io"; otherwise echo the domain unchanged.
derive_panel_domain() {
  local domain="$1" ip="$2"
  if [ -n "$domain" ]; then
    printf '%s\n' "$domain"
    return 0
  fi
  printf '%s.sslip.io\n' "${ip//./-}"
}

# validate_required_env <version> <tg_token> <tg_users> <provider>
# Reads provider-specific keys from the environment. Prints the name of the
# first missing var to stderr and returns 1; returns 0 if all present.
# Note: PANEL_EMAIL is optional — without it the web-setup registers the
# Let's Encrypt cert with --register-unsafely-without-email. PANEL_DOMAIN is
# optional too (empty -> auto <ip>.sslip.io via derive_panel_domain).
validate_required_env() {
  local version="$1" tg_token="$2" tg_users="$3" provider="$4"
  local missing=""
  [ -z "$version" ]  && missing="HERMES_VERSION"
  [ -z "$tg_token" ] && missing="${missing:-TELEGRAM_BOT_TOKEN}"
  [ -z "$tg_users" ] && missing="${missing:-TELEGRAM_ALLOWED_USERS}"
  case "$provider" in
    openai-codex) : ;;
    openrouter)   [ -z "${OPENROUTER_API_KEY:-}" ] && missing="${missing:-OPENROUTER_API_KEY}" ;;
    custom)
      [ -z "${CUSTOM_BASE_URL:-}" ] && missing="${missing:-CUSTOM_BASE_URL}"
      [ -z "${CUSTOM_API_KEY:-}" ]  && missing="${missing:-CUSTOM_API_KEY}"
      [ -z "${CUSTOM_MODEL:-}" ]    && missing="${missing:-CUSTOM_MODEL}" ;;
    *) printf 'unknown PROVIDER: %s\n' "$provider" >&2; return 1 ;;
  esac
  if [ -n "$missing" ]; then
    printf 'missing required env: %s\n' "$missing" >&2
    return 1
  fi
  return 0
}

# build_telegram_env_lines <token> <users_csv> [group_chats_csv]
# Emits .env lines for the Telegram gateway. Group line only if arg present.
build_telegram_env_lines() {
  local token="$1" users="$2" groups="${3:-}"
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$token"
  printf 'TELEGRAM_ALLOWED_USERS=%s\n' "$users"
  if [ -n "$groups" ]; then
    printf 'TELEGRAM_GROUP_ALLOWED_CHATS=%s\n' "$groups"
  fi
}

# gen_panel_password — 24 url-safe chars from the system CSPRNG.
gen_panel_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9_-' < /dev/urandom | head -c 24
  printf '\n'
}

# provider_config_commands <provider>
# Emits the `hermes config set ...` argument strings (one per line) for the
# given provider. API keys are NOT set here — they go into ~/.hermes/.env.
# NOTE: model key is `model.default` per research; Task 9 live-verifies vs `model.model`.
provider_config_commands() {
  local provider="$1"
  case "$provider" in
    openai-codex)
      printf 'config set model.provider openai-codex\n'
      ;;
    openrouter)
      printf 'config set model.provider openrouter\n'
      [ -n "${OPENROUTER_MODEL:-}" ] && printf 'config set model.default %s\n' "$OPENROUTER_MODEL"
      ;;
    custom)
      printf 'config set model.provider custom\n'
      printf 'config set model.base_url %s\n' "${CUSTOM_BASE_URL:?}"
      printf 'config set model.default %s\n' "${CUSTOM_MODEL:?}"
      ;;
    *) printf 'unknown provider: %s\n' "$provider" >&2; return 1 ;;
  esac
}

# healthcheck_dashboard <port> [curl_fn] [retries] [sleep_s]
# curl_fn echoes an HTTP status code for http://127.0.0.1:<port>/.
# Polls up to <retries> times (default 20, 2s apart) because the dashboard
# (esp. with --tui) takes a few seconds to start. Returns 0 if 2xx/3xx/401.
healthcheck_dashboard() {
  local port="$1" curl_fn="${2:-_real_curl_status}" retries="${3:-20}" sleep_s="${4:-2}"
  local code="" i
  for i in $(seq 1 "$retries"); do
    code="$("$curl_fn" "$port")"
    case "$code" in
      2??|3??|401) return 0 ;;   # 401 = nginx Basic Auth up = dashboard reachable
    esac
    [ "$i" -lt "$retries" ] && sleep "$sleep_s"
  done
  printf 'dashboard healthcheck got HTTP %s\n' "$code" >&2
  return 1
}

_real_curl_status() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$1/" || echo "000"
}
