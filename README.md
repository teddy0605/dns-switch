# dns-switch

A macOS menu bar app that connects a GlobalProtect VPN and keeps split DNS
correct around it.

You click **Connect VPN…**, pick a gateway, and type your password and 2FA
code. Work domains then resolve through the VPN DNS servers. Everything else
goes to your normal resolver, for example a Pi-hole at home. When you
disconnect, DNS switches back on its own. You do not need a Terminal window.

## Features

- **One DNS setup for every situation.** `activate` detects your location (home
  or office) and the VPN state, then writes the matching `dnsmasq` config.
- **Split DNS.** `dnsmasq` runs on `127.0.0.1:53`. Work domains go to the VPN
  DNS servers through `/etc/resolver` files.
- **Block list.** `dnsmasq` sends domains in `BLOCKED_DOMAINS` to `0.0.0.0` in
  every mode.
- **VPN connect from the menu bar.** A dialog asks for the gateway, password
  and 2FA code. Nothing is stored: the answers go to `openconnect` on stdin.
- **DNS follows the VPN.** `vpn-hook.sh` runs `activate` when the tunnel goes up
  or down, so DNS never stays on the old setup.
- **Watchdog.** The app runs `check` every 5 seconds. After two failures in a
  row, it runs `activate` again. If that fails, it shows an alert.
- **Certificate pinning.** When a gateway has an unknown certificate, the app
  shows its pin and asks before it trusts it.

The menu bar icon shows the state:

```text
globe              DNS active, VPN off
globe + shield     DNS active, VPN on
crossed-out globe  dnsmasq is not running
```

## Requirements

- macOS on Apple silicon, with Homebrew in `/opt/homebrew`
- `dnsmasq` and `openconnect`
- Xcode Command Line Tools, which provide `swiftc` to build the menu bar app
- Passwordless `sudo` for `dns-switch.sh`, because the app runs `sudo -n`

## Setup

Install the tools:

```bash
brew install dnsmasq openconnect
```

Create your local config, then edit it with your own DNS servers, domains and
VPN details:

```bash
mkdir -p local && cp dns-switch.env.example local/.env
```

Allow the app to run the script with `sudo` and no password prompt. Run
`sudo visudo -f /etc/sudoers.d/dns-switch` and add this line, with your user
name and path:

```text
youruser ALL=(root) NOPASSWD: /path/to/dns-switch/dns-switch.sh
```

Build and start the menu bar app. It installs to `~/Applications/DNS Switch.app`:

```bash
./menubar/build.sh
```

If your gateway runs a HIP check (the endpoint compliance check of
GlobalProtect), put your own CSD wrapper at `local/hipreport.sh`. The repo does not
include one.

## Commands

```bash
sudo ./dns-switch.sh activate         # detect location + VPN state and apply the DNS config
sudo ./dns-switch.sh deactivate       # stop dnsmasq and restore DHCP DNS
sudo ./dns-switch.sh flush            # flush the macOS and dnsmasq DNS caches
sudo ./dns-switch.sh status           # show dnsmasq, resolver and lookup status
sudo ./dns-switch.sh logs [-f]        # show or follow the dnsmasq query log
sudo ./dns-switch.sh vpn-connect <gw> # connect the VPN; password and 2FA code on stdin
sudo ./dns-switch.sh vpn-disconnect   # disconnect the VPN cleanly, like Ctrl+C
sudo ./dns-switch.sh vpn-trust <pin>  # trust a portal or gateway certificate pin
sudo ./dns-switch.sh cleanup-routes   # remove stale routes after a crashed VPN session
./dns-switch.sh check                 # exit 1 if the live DNS setup is stale
```

Domain lists:

```bash
sudo ./dns-switch.sh add-domain <d>           # add a work domain
sudo ./dns-switch.sh block-domain <d>         # add a domain to the block list
```

Each `add-` and `block-` command has a matching `remove-` or `unblock-` command.

## Config

`dns-switch.sh` reads `local/.env`. See `dns-switch.env.example` for all keys:

```text
PIHOLE_IP            home DNS server; if it answers, you are at home
VPN_DNS_1, VPN_DNS_2 DNS servers inside the VPN
WORK_DOMAINS         domains that resolve through the VPN DNS servers
BLOCKED_DOMAINS      domains that resolve to 0.0.0.0
VPN_PORTAL, VPN_USER GlobalProtect portal and user name
VPN_SERVERCERTS      trusted certificate pins, one per portal or gateway
VPN_BOOTSTRAP_HOSTS  portal and gateway hosts that must use public DNS
VPN_GATEWAYS         gateway names for the menu bar picker; the first is the default
```

Keep private files in `local/`. `.gitignore` excludes that folder.
