# fail2ban (sshd jail)

Brute-force throttling for kai-server's public sshd listener. Bans a
source IP after repeated failed-auth attempts. No sshd binding, firewall
topology, or exposure change.

Tracker: [coilyco-flight-deck/infrastructure#104](https://forgejo.coilysiren.me/coilyco-flight-deck/infrastructure/issues/104).
Parent audit: [coilyco-flight-deck/infrastructure#103](https://forgejo.coilysiren.me/coilyco-flight-deck/infrastructure/issues/103).

## Why

sshd listens on `0.0.0.0:22` and takes continuous bot brute-force scans.
Both `fail2ban` and `sshguard` were `inactive`, so nothing throttled
repeated failed auth. This is the lowest-risk immediate hardening: it
does not depend on resolving the broader exposure question (router
port-forwards, the tangled-knot git-SSH path) tracked in the parent
audit. It just bans IPs after `maxretry` failed attempts.

## What ships

- **`fail2ban/jail.local`** - explicit policy installed to
  `/etc/fail2ban/jail.local`. Enables the `sshd` jail with the systemd
  journal backend (modern Ubuntu logs sshd to the journal, not a plain
  `/var/log/auth.log`). 1h ban, 5 failures over a 10m window. `ignoreip`
  covers loopback and RFC1918 ranges so a fat-fingered key from the LAN
  or over tailscale can never lock Kai out. `jail.local` overrides
  `jail.conf` and survives package upgrades.
- **`scripts/fail2ban-install.sh`** - idempotent installer. Installs the
  package if absent, drops `jail.local`, enables + restarts the service,
  prints status.

## Install

Run on kai-server:

```
bash /home/kai/projects/coilysiren/infrastructure/scripts/fail2ban-install.sh
```

## Verify

```
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

`status sshd` reports the failed/banned counts and the current banned
IP list. `scripts/host-diag.sh` also dumps both in its FAIL2BAN section.

## Tuning

Edit `fail2ban/jail.local`, re-run the installer (or
`sudo systemctl reload fail2ban`). To unban an IP:

```
sudo fail2ban-client set sshd unbanip <IP>
```
