#!/usr/bin/env bash
# Non-interactive Hermes installer. Run as root on a clean Ubuntu box.
# Driven entirely by environment variables (see plan env-var contract).
#
# Pinned-install mechanism: install_hermes_pinned() currently uses the
# install.sh `--branch <tag>` path. This is PENDING live verification on
# hermes-test (plan Task 1). If the branch/tag pin does not yield the pinned
# version, swap the body for the pip path:
#   run_as_hermes "pipx install hermes-agent==${HERMES_VERSION#v} || pip install --user hermes-agent==${HERMES_VERSION#v}"
# Record the winning mechanism in tests/INTEGRATION.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hermes-install-helpers.sh disable=SC1091
source "${SCRIPT_DIR}/lib/hermes-install-helpers.sh"

# Lib-only mode for tests: stop after defining/sourcing functions.
# Works both when sourced (return) and when executed directly (exit).
if [ "${HERMES_UNATTENDED_LIB_ONLY:-0}" = "1" ]; then
  # shellcheck disable=SC2317  # reachable only in the executed-directly case
  return 0 2>/dev/null || exit 0
fi

HERMES_HOME_USER="hermes"
RAW_BASE="https://raw.githubusercontent.com/dentistrasvibe/hermes-guide-scripts/main"

log() { printf '::step:: %s\n' "$*"; }

require_root_ubuntu() {
  [ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
  grep -qi ubuntu /etc/os-release || { echo "Ubuntu required" >&2; exit 1; }
  getent hosts github.com >/dev/null || { echo "no network" >&2; exit 1; }
}

run_as_hermes() { su - "$HERMES_HOME_USER" -c "$1"; }

# Run a reused helper script. Prefer a local copy sitting next to this
# orchestrator (so you can clone the branch and test BEFORE pushing/merging);
# fall back to fetching the published version from RAW_BASE (main) otherwise.
run_reused_script() {  # run_reused_script <name> [args...]
  local name="$1"; shift
  local local_path="${SCRIPT_DIR}/${name}"
  if [ -f "$local_path" ]; then
    bash "$local_path" "$@"
  else
    bash <(curl -fsSL "${RAW_BASE}/${name}") "$@"
  fi
}

install_hermes_pinned() {
  # PENDING Task 1 live verification — see header comment.
  run_as_hermes "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --branch ${HERMES_VERSION}"
}

main() {
  local ip domain pass

  require_root_ubuntu

  validate_required_env "${HERMES_VERSION:-}" \
    "${TELEGRAM_BOT_TOKEN:-}" "${TELEGRAM_ALLOWED_USERS:-}" "${PROVIDER:-}"

  ip="$(curl -fsSL --max-time 5 https://api.ipify.org)"
  domain="$(derive_panel_domain "${PANEL_DOMAIN:-}" "$ip")"
  pass="${PANEL_PASS:-$(gen_panel_password)}"

  log "preflight"
  run_reused_script prepare-hermes-server.sh

  log "install hermes ${HERMES_VERSION}"
  install_hermes_pinned

  log "write provider .env"
  install -d -o "$HERMES_HOME_USER" -g "$HERMES_HOME_USER" "/home/${HERMES_HOME_USER}/.hermes"
  {
    case "${PROVIDER}" in
      openrouter) printf 'OPENROUTER_API_KEY=%s\n' "$OPENROUTER_API_KEY" ;;
      custom)     printf 'OPENAI_API_KEY=%s\nOPENAI_BASE_URL=%s\n' "$CUSTOM_API_KEY" "$CUSTOM_BASE_URL" ;;
    esac
    build_telegram_env_lines "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_ALLOWED_USERS" "${TELEGRAM_GROUP_ALLOWED_CHATS:-}"
  } >> "/home/${HERMES_HOME_USER}/.hermes/.env"
  chown "$HERMES_HOME_USER:$HERMES_HOME_USER" "/home/${HERMES_HOME_USER}/.hermes/.env"
  chmod 600 "/home/${HERMES_HOME_USER}/.hermes/.env"

  log "configure provider"
  while IFS= read -r args; do
    [ -n "$args" ] && run_as_hermes "hermes $args"
  done < <(provider_config_commands "$PROVIDER")

  if [ "$PROVIDER" = "openai-codex" ]; then
    log "oauth: hermes auth add openai-codex (interactive — driven by caller/P2)"
    run_as_hermes "hermes auth add openai-codex"
  fi

  log "telegram gateway service"
  run_as_hermes "hermes gateway install --system" || hermes gateway install --system

  log "web panel"
  # Export so the values reach the child bash even through run_reused_script
  # (a function — an inline `VAR=x func` prefix would not propagate reliably).
  export PANEL_USER=hermes PANEL_PASS="$pass" DOMAIN="$domain" EMAIL="${PANEL_EMAIL:-}"
  run_reused_script setup-hermes-web.sh

  log "hermes update"
  run_as_hermes "hermes update" || true   # Task 1 decides whether update un-pins

  log "healthcheck"
  healthcheck_dashboard 9119

  printf '\n::done:: panel=https://%s login=hermes password=%s\n' "$domain" "$pass"
}

main "$@"
