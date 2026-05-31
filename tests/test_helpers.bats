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
