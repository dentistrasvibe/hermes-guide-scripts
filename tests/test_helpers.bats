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

@test "validate_required_env: missing PANEL_EMAIL fails with message" {
  run validate_required_env "v0.14.0" "" "tok" "111" "openrouter"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PANEL_EMAIL"* ]]
}

@test "validate_required_env: openrouter without key fails" {
  OPENROUTER_API_KEY="" run validate_required_env "v0.14.0" "a@b.c" "tok" "111" "openrouter"
  [ "$status" -ne 0 ]
  [[ "$output" == *"OPENROUTER_API_KEY"* ]]
}

@test "validate_required_env: complete openrouter passes" {
  OPENROUTER_API_KEY="sk-or-1" run validate_required_env "v0.14.0" "a@b.c" "tok" "111" "openrouter"
  [ "$status" -eq 0 ]
}
