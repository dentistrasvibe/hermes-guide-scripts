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

# validate_required_env <version> <email> <tg_token> <tg_users> <provider>
# Reads provider-specific keys from the environment. Prints the name of the
# first missing var to stderr and returns 1; returns 0 if all present.
validate_required_env() {
  local version="$1" email="$2" tg_token="$3" tg_users="$4" provider="$5"
  local missing=""
  [ -z "$version" ]  && missing="HERMES_VERSION"
  [ -z "$email" ]    && missing="${missing:-PANEL_EMAIL}"
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
