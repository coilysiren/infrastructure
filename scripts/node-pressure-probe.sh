#!/usr/bin/env bash
# Sample node-global pressure during DinD load (conntrack, loadavg, apiserver
# latency) to find what degrades the control plane. Read-only. See §7 runbook.

# Usage: node-pressure-probe.sh <label> <seconds> [interval=2] [outdir=/tmp]
set -euo pipefail

label="${1:?label required}"
seconds="${2:?seconds required}"
interval="${3:-2}"
outdir="${4:-/tmp}"
out="${outdir}/node-pressure-${label}.csv"

ct_max="$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
ncpu="$(nproc)"

echo "epoch,label,conntrack_count,conntrack_max,conntrack_pct,load1,load_per_cpu_pct,apiserver_connect_ms,apiserver_total_ms,apiserver_code" >"$out"

end=$(( $(date +%s) + seconds ))
while [ "$(date +%s)" -lt "$end" ]; do
  now="$(date +%s)"
  ct="$(cat /proc/sys/net/netfilter/nf_conntrack_count)"
  ct_pct=$(( ct * 100 / ct_max ))
  load1="$(cut -d' ' -f1 /proc/loadavg)"
  # load relative to core count, as integer percent
  load_pct="$(awk -v l="$load1" -v n="$ncpu" 'BEGIN{printf "%d", (l/n)*100}')"
  # apiserver responsiveness: connect + total time and HTTP code for /livez
  read -r c_connect c_total c_code < <(curl -ks -o /dev/null \
    -w '%{time_connect} %{time_total} %{http_code}\n' \
    --max-time 5 https://127.0.0.1:6443/livez 2>/dev/null || echo "TIMEOUT TIMEOUT 000")
  # seconds -> ms (guard against TIMEOUT sentinel)
  if [ "$c_connect" = "TIMEOUT" ]; then
    connect_ms="TIMEOUT"; total_ms="TIMEOUT"
  else
    connect_ms="$(awk -v s="$c_connect" 'BEGIN{printf "%d", s*1000}')"
    total_ms="$(awk -v s="$c_total" 'BEGIN{printf "%d", s*1000}')"
  fi
  echo "${now},${label},${ct},${ct_max},${ct_pct},${load1},${load_pct},${connect_ms},${total_ms},${c_code}" >>"$out"
  sleep "$interval"
done

echo "wrote $out"
# Quick summary: peak conntrack%, peak load%, worst apiserver total_ms, any non-200
awk -F, 'NR>1{
  if($5>ctp)ctp=$5; if($7>lp)lp=$7;
  if($9!="TIMEOUT" && $9>mt)mt=$9; if($9=="TIMEOUT")to++;
  if($10!="200" && $10!="")bad++
}
END{printf "SUMMARY %s: peak_conntrack=%d%% peak_load=%d%% worst_apiserver=%sms timeouts=%d non200=%d\n", L, ctp, lp, (mt==""?"NA":mt), to+0, bad+0}' L="$label" "$out"
