#!/bin/bash
# openconnect --script hook: runs the stock vpnc-script, then re-applies
# dns-switch for the new VPN state. openconnect is still running when
# "disconnect" fires, so DNS_SWITCH_VPN=no tells activate the VPN is gone.
/opt/homebrew/etc/vpnc/vpnc-script || exit

DNS_SWITCH="$(dirname "$0")/dns-switch.sh"
case "${reason:-}" in
  connect) "$DNS_SWITCH" activate || true ;;
  disconnect) DNS_SWITCH_VPN=no "$DNS_SWITCH" activate || true ;;
esac
