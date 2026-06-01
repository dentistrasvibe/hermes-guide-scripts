#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/hermes-install-helpers.sh"
}

@test "derive_panel_domain: empty domain -> sslip.io from IP" {
  run derive_panel_domain "" "203.0.113.7"
  [ "$status" -eq 0 ]
  [ "$output" = "203-0-113-7.sslip.io" ]
}

@test "derive_panel_domain: explicit domain passes through" {
  run derive_panel_domain "agent.example.com" "203.0.113.7"
  [ "$status" -eq 0 ]
  [ "$output" = "agent.example.com" ]
}

@test "validate_required_env: missing TELEGRAM_BOT_TOKEN fails with message" {
  run validate_required_env "v2026.5.29.2" "" "111" "openrouter"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TELEGRAM_BOT_TOKEN"* ]]
}

@test "validate_required_env: passes without an email (email is optional)" {
  OPENROUTER_API_KEY="sk-or-1" run validate_required_env "v2026.5.29.2" "tok" "111" "openrouter"
  [ "$status" -eq 0 ]
}

@test "validate_required_env: openrouter without key fails" {
  OPENROUTER_API_KEY="" run validate_required_env "v2026.5.29.2" "tok" "111" "openrouter"
  [ "$status" -ne 0 ]
  [[ "$output" == *"OPENROUTER_API_KEY"* ]]
}

@test "validate_required_env: complete openrouter passes" {
  OPENROUTER_API_KEY="sk-or-1" run validate_required_env "v2026.5.29.2" "tok" "111" "openrouter"
  [ "$status" -eq 0 ]
}

@test "build_telegram_env_lines: emits token and CSV users" {
  run build_telegram_env_lines "123:ABC" "111,222"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TELEGRAM_BOT_TOKEN=123:ABC"* ]]
  [[ "$output" == *"TELEGRAM_ALLOWED_USERS=111,222"* ]]
}

@test "build_telegram_env_lines: supergroup -100 id preserved in group chats" {
  run build_telegram_env_lines "123:ABC" "111" "-100999"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TELEGRAM_GROUP_ALLOWED_CHATS=-100999"* ]]
}

@test "gen_panel_password: returns 24+ url-safe chars" {
  run gen_panel_password
  [ "$status" -eq 0 ]
  [ "${#output}" -ge 24 ]
  [[ "$output" =~ ^[A-Za-z0-9_-]+$ ]]
}

@test "gen_panel_password: two calls differ" {
  a="$(gen_panel_password)"; b="$(gen_panel_password)"
  [ "$a" != "$b" ]
}

@test "provider_config_commands: openai-codex sets provider only" {
  run provider_config_commands "openai-codex"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config set model.provider openai-codex"* ]]
}

@test "provider_config_commands: custom sets provider, base_url, default" {
  CUSTOM_BASE_URL="https://x/v1" CUSTOM_MODEL="m1" run provider_config_commands "custom"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config set model.provider custom"* ]]
  [[ "$output" == *"config set model.base_url https://x/v1"* ]]
  [[ "$output" == *"config set model.default m1"* ]]
}

@test "provider_config_commands: openrouter sets provider and default" {
  OPENROUTER_MODEL="anthropic/claude-opus-4.6" run provider_config_commands "openrouter"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config set model.provider openrouter"* ]]
  [[ "$output" == *"config set model.default anthropic/claude-opus-4.6"* ]]
}

@test "healthcheck_dashboard: 200 -> ok" {
  fake_curl() { echo "200"; }
  run healthcheck_dashboard 9119 fake_curl 1 0
  [ "$status" -eq 0 ]
}

@test "healthcheck_dashboard: 000 (down) -> fail" {
  fake_curl() { echo "000"; }
  run healthcheck_dashboard 9119 fake_curl 1 0
  [ "$status" -ne 0 ]
}

@test "healthcheck_dashboard: retries then succeeds" {
  # fail twice, then 200 — proves the poll loop retries instead of one-shot.
  # File-based counter because curl_fn runs in a command-substitution subshell.
  cnt="$(mktemp)"; echo 0 > "$cnt"
  fake_curl() { local n; n=$(( $(cat "$cnt") + 1 )); echo "$n" > "$cnt"; if [ "$n" -ge 3 ]; then echo 200; else echo 000; fi; }
  run healthcheck_dashboard 9119 fake_curl 5 0
  rm -f "$cnt"
  [ "$status" -eq 0 ]
}
