#!/usr/bin/env bash
# Capture post-incident diagnostic snapshot from a remote host.
# Intended to be streamed via: ssh <host> -- bash -s < scripts/host-diag.sh
# Writes to /tmp/host-diag-<UTC-ts>.txt on the remote AND streams to stdout.
set +e
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/tmp/host-diag-${TS}.txt"
exec > >(tee "$OUT") 2>&1

section() { printf '\n\n===== %s =====\n' "$1"; }

section "META"
date -u
hostname
uptime
who -b
echo "uptime_seconds=$(awk '{print $1}' /proc/uptime)"

section "LOAD / MEMORY / PRESSURE"
cat /proc/loadavg
free -h
cat /proc/pressure/cpu 2>/dev/null
cat /proc/pressure/memory 2>/dev/null
cat /proc/pressure/io 2>/dev/null

section "LISTENING SOCKETS"
sudo ss -tlnp

section "SSHD STATE"
sudo systemctl status ssh --no-pager -l | head -40
sudo systemctl show ssh -p ActiveState,SubState,Result,NRestarts,ExecMainStartTimestamp

section "RECENT SYSTEMD UNIT RESTARTS (last 2h)"
sudo journalctl --since '2 hours ago' -o cat -u systemd -p info..err | grep -iE 'starting|started|stopping|stopped|failed|reload' | tail -60

section "SSH JOURNAL (last 2h)"
sudo journalctl --since '2 hours ago' -u ssh --no-pager | tail -80

section "K3S JOURNAL (last 2h, filtered)"
sudo journalctl --since '2 hours ago' -u k3s --no-pager 2>/dev/null | grep -iE 'iptables|conntrack|cni|error|warn|reconcile|sync|restart' | tail -120

section "TAILSCALED JOURNAL (last 2h, filtered)"
sudo journalctl --since '2 hours ago' -u tailscaled --no-pager 2>/dev/null | grep -iE 'error|warn|magicsock|derp|disco|netcheck|reconnect' | tail -80

section "KERNEL RING (last 200 lines)"
sudo dmesg -T --ctime | tail -200

section "OOM HITS (full boot)"
sudo dmesg -T --ctime | grep -iE 'oom|killed process|out of memory' | tail -40

section "NETFILTER / CONNTRACK MESSAGES (full boot)"
sudo dmesg -T --ctime | grep -iE 'nf_conntrack|nf_tables|netfilter|conntrack table full|dropping packet' | tail -80

section "CONNTRACK"
sudo sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_buckets 2>/dev/null
sudo conntrack -S 2>/dev/null | head -20
echo "--- top 20 conntrack sources right now ---"
sudo conntrack -L 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^src=/) {print $i; break}}' | sort | uniq -c | sort -rn | head -20

section "IPTABLES (filter)"
sudo iptables -S
echo "--- INPUT counters ---"
sudo iptables -L INPUT -v -n --line-numbers
echo "--- FORWARD counters ---"
sudo iptables -L FORWARD -v -n --line-numbers | head -40

section "IPTABLES (nat)"
sudo iptables -t nat -S | head -120

section "NFT RULESET (truncated)"
sudo nft list ruleset 2>/dev/null | head -300

section "UFW STATUS"
sudo ufw status verbose 2>/dev/null || echo "ufw not installed or not active"

section "FAIL2BAN STATUS"
sudo fail2ban-client status 2>/dev/null || echo "fail2ban not installed"
sudo fail2ban-client status sshd 2>/dev/null

section "INTERFACES / ROUTES"
ip -br addr
echo "---"
ip route
echo "--- tailscale0 ---"
ip addr show tailscale0 2>/dev/null
sudo tailscale status --self=true 2>/dev/null | head -5
sudo tailscale netcheck 2>/dev/null | head -40

section "TOP PROCESSES BY RSS"
ps -eo pid,user,rss,pcpu,comm --sort=-rss | head -20

section "RECENT AUTH LOG (last 200 lines)"
sudo tail -n 200 /var/log/auth.log 2>/dev/null

echo
echo "===== DONE: $OUT ====="
ls -la "$OUT"
