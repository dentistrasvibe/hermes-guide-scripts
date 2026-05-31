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
