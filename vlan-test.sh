#!/bin/bash
# ============================================================
#  vSphere VLAN Probe Tester
#  Runs locally on the Ubuntu probe VM.
#  Requires: govc installed on this VM, sudo without password.
# ============================================================

# --- vCenter Config ---
export GOVC_URL="https://vcenter.lab.local"
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD="yourpassword"
export GOVC_INSECURE=1

# --- VM Config ---
VM_NAME="ubuntu-probe"        # exact VM name as shown in vCenter
MGMT_IFACE="ens160"           # management NIC - never touched during tests
MGMT_MODE="dhcp"              # "dhcp" or "static"

# Only used when MGMT_MODE="static":
MGMT_STATIC_IP="10.0.0.50/24"
MGMT_STATIC_GW="10.0.0.1"
MGMT_STATIC_DNS="8.8.8.8"

IFACE="ens192"                # test NIC - rotated between VLANs by the script

# --- DNS test settings ---
DNS_SERVER="8.8.8.8"
DNS_HOSTNAME="google.com"

# --- HTTP/S endpoints to test per VLAN (optional, leave empty to skip) ---
# Format: "url|expected_http_code" — index matches VLANS array
HTTP_TESTS=(
  "http://192.168.10.1|200"
  "http://192.168.20.1|200"
)

# --- VLANs to test ---
# Format: "PortGroupName|IP/prefix|Gateway|Description"
VLANS=(
  "PG-VLAN10|192.168.10.100/24|192.168.10.1|Server VLAN"
  "PG-VLAN20|192.168.20.100/24|192.168.20.1|User VLAN"
  "PG-VLAN30|192.168.30.100/24|192.168.30.1|DMZ VLAN"
)

# --- Extra hosts to ping per VLAN (beyond gateway, optional) ---
# Format: "PG-Name|host1 host2 host3"
EXTRA_PING=(
  "PG-VLAN10|192.168.10.10 192.168.10.20"
  "PG-VLAN20|192.168.20.10"
)

# --- Output ---
REPORT_DIR="$(pwd)/vlan-reports"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
JSON_FILE="$REPORT_DIR/results_$TIMESTAMP.json"
HTML_FILE="$REPORT_DIR/report_$TIMESTAMP.html"
mkdir -p "$REPORT_DIR"

# ============================================================
#  Helpers
# ============================================================
PASS="PASS"
FAIL="FAIL"
WARN="WARN"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
pass() { echo "    ✓ $*"; }
fail() { echo "    ✗ $*"; }

# ============================================================
#  JSON builder
# ============================================================
JSON_RESULTS="[]"

append_result() {
  local pg="$1" desc="$2" test="$3" status="$4" detail="$5"
  JSON_RESULTS=$(echo "$JSON_RESULTS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data.append({'portgroup': '$pg', 'description': '$desc', 'test': '$test', 'status': '$status', 'detail': $(echo "$detail" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")})
print(json.dumps(data))
")
}

# ============================================================
#  Management NIC setup
# ============================================================
setup_mgmt_nic() {
  log "Configuring management NIC ($MGMT_IFACE) — mode: $MGMT_MODE..."

  if [ "$MGMT_MODE" = "static" ]; then
    sudo ip link set "$MGMT_IFACE" up
    sudo ip addr flush dev "$MGMT_IFACE"
    sudo ip addr add "$MGMT_STATIC_IP" dev "$MGMT_IFACE"
    sudo ip route add default via "$MGMT_STATIC_GW" 2>/dev/null || true
    pass "Management NIC configured: $MGMT_STATIC_IP via $MGMT_STATIC_GW"

  elif [ "$MGMT_MODE" = "dhcp" ]; then
    sudo ip link set "$MGMT_IFACE" up
    sudo dhclient -r "$MGMT_IFACE" 2>/dev/null
    sudo dhclient "$MGMT_IFACE" 2>/dev/null
    MGMT_ADDR=$(ip addr show "$MGMT_IFACE" | grep 'inet ' | awk '{print $2}')
    if [ -n "$MGMT_ADDR" ]; then
      pass "Management NIC got DHCP lease: $MGMT_ADDR"
    else
      echo "ERROR: Management NIC did not get a DHCP lease."
      exit 1
    fi

  else
    echo "ERROR: MGMT_MODE must be 'dhcp' or 'static'. Got: $MGMT_MODE"
    exit 1
  fi
}

# ============================================================
#  Pre-flight checks
# ============================================================
log "Pre-flight: checking govc..."
if ! command -v govc &>/dev/null; then
  echo "ERROR: govc not found. Install from https://github.com/vmware/govmomi/releases"
  exit 1
fi

log "Pre-flight: checking vCenter connection..."
if ! govc about &>/dev/null; then
  echo "ERROR: Cannot connect to vCenter at $GOVC_URL"
  exit 1
fi

log "Pre-flight: installing test tools if needed..."
which nmap &>/dev/null || sudo apt-get install -y nmap dnsutils curl &>/dev/null

log "Pre-flight: setting up management NIC..."
setup_mgmt_nic

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        vSphere VLAN Probe Tester         ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  VM      : $VM_NAME"
echo "  Mgmt NIC: $MGMT_IFACE ($MGMT_MODE)"
echo "  Test NIC: $IFACE"
echo ""

# ============================================================
#  Main test loop
# ============================================================
declare -A EXTRA_MAP
for entry in "${EXTRA_PING[@]}"; do
  IFS='|' read -r k v <<< "$entry"
  EXTRA_MAP[$k]="$v"
done

for i in "${!VLANS[@]}"; do
  IFS='|' read -r PG IP GW DESC <<< "${VLANS[$i]}"

  echo "┌─────────────────────────────────────────"
  echo "│  [$((i+1))/${#VLANS[@]}] $PG — $DESC"
  echo "│  IP: $IP  GW: $GW"
  echo "└─────────────────────────────────────────"

  # 1. Switch port group via govc
  log "Switching $IFACE to port group: $PG"
  PG_OUTPUT=$(govc vm.network.change -vm "$VM_NAME" -net "$PG" ethernet-1 2>&1)
  if [ $? -eq 0 ]; then
    pass "Port group switched"
    append_result "$PG" "$DESC" "Port Group Switch" "$PASS" "Switched to $PG"
  else
    fail "Port group switch failed: $PG_OUTPUT"
    append_result "$PG" "$DESC" "Port Group Switch" "$FAIL" "$PG_OUTPUT"
    echo "  → Skipping remaining tests for this VLAN"
    echo ""
    continue
  fi
  sleep 3

  # 2. Re-IP the test interface locally
  log "Reconfiguring $IFACE to $IP..."
  sudo ip link set "$IFACE" down
  sudo ip link set "$IFACE" up
  sudo ip addr flush dev "$IFACE"
  sudo ip addr add "$IP" dev "$IFACE"
  sudo ip route flush default 2>/dev/null
  sudo ip route add default via "$GW"

  ASSIGNED=$(ip addr show "$IFACE" | grep 'inet ' | awk '{print $2}')
  if [ "$ASSIGNED" = "$IP" ]; then
    pass "Interface configured: $IP via $GW"
    append_result "$PG" "$DESC" "Interface Config" "$PASS" "$IP on $IFACE, gw $GW"
  else
    fail "Interface config issue — assigned: ${ASSIGNED:-none}"
    append_result "$PG" "$DESC" "Interface Config" "$WARN" "Expected $IP, got ${ASSIGNED:-none}"
  fi
  sleep 2

  # 3. Ping gateway
  log "Ping gateway $GW..."
  PING_OUT=$(ping -c 4 -W 2 "$GW" 2>&1)
  PING_LOSS=$(echo "$PING_OUT" | grep -oP '\d+(?=% packet loss)')
  if [ "$PING_LOSS" = "0" ]; then
    RTT=$(echo "$PING_OUT" | grep -oP 'rtt.*= \K[\d.]+(?=/)' | head -1)
    pass "Gateway reachable (RTT: ${RTT}ms, 0% loss)"
    append_result "$PG" "$DESC" "Ping Gateway" "$PASS" "0% loss, RTT ${RTT}ms"
  elif [ -n "$PING_LOSS" ] && [ "$PING_LOSS" -lt 100 ]; then
    fail "Gateway partially reachable ($PING_LOSS% loss)"
    append_result "$PG" "$DESC" "Ping Gateway" "$WARN" "${PING_LOSS}% packet loss"
  else
    fail "Gateway unreachable ($GW)"
    append_result "$PG" "$DESC" "Ping Gateway" "$FAIL" "100% packet loss"
  fi

  # 4. Ping extra hosts (if defined)
  if [ -n "${EXTRA_MAP[$PG]}" ]; then
    for HOST in ${EXTRA_MAP[$PG]}; do
      log "Ping extra host $HOST..."
      EPING=$(ping -c 3 -W 2 "$HOST" 2>&1)
      ELOSS=$(echo "$EPING" | grep -oP '\d+(?=% packet loss)')
      if [ "$ELOSS" = "0" ]; then
        pass "Host $HOST reachable"
        append_result "$PG" "$DESC" "Ping $HOST" "$PASS" "0% loss"
      else
        fail "Host $HOST unreachable"
        append_result "$PG" "$DESC" "Ping $HOST" "$FAIL" "${ELOSS:-100}% loss"
      fi
    done
  fi

  # 5. DNS resolution
  log "DNS resolution test (via $DNS_SERVER)..."
  DNS_OUT=$(dig @"$DNS_SERVER" "$DNS_HOSTNAME" +short +time=3 2>&1)
  if echo "$DNS_OUT" | grep -qP '^\d+\.\d+\.\d+\.\d+'; then
    pass "DNS resolved $DNS_HOSTNAME → $(echo "$DNS_OUT" | head -1)"
    append_result "$PG" "$DESC" "DNS Resolution" "$PASS" "$DNS_HOSTNAME → $(echo "$DNS_OUT" | head -1)"
  else
    fail "DNS resolution failed: $DNS_OUT"
    append_result "$PG" "$DESC" "DNS Resolution" "$FAIL" "$DNS_OUT"
  fi

  # 6. HTTP check (matched to VLAN index)
  HTTP_URL=$(echo "${HTTP_TESTS[$i]}" | cut -d'|' -f1)
  HTTP_EXPECTED=$(echo "${HTTP_TESTS[$i]}" | cut -d'|' -f2)
  if [ -n "$HTTP_URL" ]; then
    log "HTTP test: $HTTP_URL (expect $HTTP_EXPECTED)..."
    HTTP_OUT=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$HTTP_URL" 2>&1)
    if [ "$HTTP_OUT" = "$HTTP_EXPECTED" ]; then
      pass "HTTP $HTTP_URL → $HTTP_OUT"
      append_result "$PG" "$DESC" "HTTP $HTTP_URL" "$PASS" "Got HTTP $HTTP_OUT"
    else
      fail "HTTP $HTTP_URL → got $HTTP_OUT, expected $HTTP_EXPECTED"
      append_result "$PG" "$DESC" "HTTP $HTTP_URL" "$FAIL" "Got HTTP $HTTP_OUT, expected $HTTP_EXPECTED"
    fi
  fi

  # 7. Port scan gateway (top 20 ports)
  log "Port scan gateway $GW (top 20 ports)..."
  NMAP_OUT=$(sudo nmap -T4 --top-ports 20 "$GW" 2>&1)
  OPEN_PORTS=$(echo "$NMAP_OUT" | grep '/tcp' | grep 'open' | awk '{print $1}' | tr '\n' ' ')
  if [ -n "$OPEN_PORTS" ]; then
    pass "Open ports on $GW: $OPEN_PORTS"
    append_result "$PG" "$DESC" "Port Scan GW" "$PASS" "Open: $OPEN_PORTS"
  else
    fail "No open ports found on $GW (or host down)"
    append_result "$PG" "$DESC" "Port Scan GW" "$WARN" "No open ports detected"
  fi

  # 8. MTU test
  log "MTU test (ping with 1400 byte payload)..."
  MTU_OUT=$(ping -c 2 -W 2 -M do -s 1400 "$GW" 2>&1)
  if echo "$MTU_OUT" | grep -q "2 received\|1 received"; then
    pass "MTU 1400 OK"
    append_result "$PG" "$DESC" "MTU Test (1400)" "$PASS" "Large frames passing"
  else
    fail "MTU test failed (fragmentation or packet loss)"
    append_result "$PG" "$DESC" "MTU Test (1400)" "$WARN" "1400-byte frames dropped — possible MTU mismatch"
  fi

  echo ""
done

# ============================================================
#  Save JSON
# ============================================================
echo "$JSON_RESULTS" | python3 -m json.tool > "$JSON_FILE"
log "JSON results saved: $JSON_FILE"

# ============================================================
#  Generate HTML Report
# ============================================================
log "Generating HTML report..."

PASS_COUNT=$(grep -o '"status": "PASS"' "$JSON_FILE" | wc -l)
FAIL_COUNT=$(grep -o '"status": "FAIL"' "$JSON_FILE" | wc -l)
WARN_COUNT=$(grep -o '"status": "WARN"' "$JSON_FILE" | wc -l)

python3 << PYEOF
import json, datetime

with open("$JSON_FILE") as f:
    results = json.load(f)

ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
pass_c = sum(1 for r in results if r['status'] == 'PASS')
fail_c = sum(1 for r in results if r['status'] == 'FAIL')
warn_c = sum(1 for r in results if r['status'] == 'WARN')
total  = len(results)

groups = {}
for r in results:
    pg = r['portgroup']
    if pg not in groups:
        groups[pg] = {'desc': r['description'], 'tests': []}
    groups[pg]['tests'].append(r)

rows = ""
for pg, data in groups.items():
    pg_pass = sum(1 for t in data['tests'] if t['status'] == 'PASS')
    pg_fail = sum(1 for t in data['tests'] if t['status'] == 'FAIL')
    pg_warn = sum(1 for t in data['tests'] if t['status'] == 'WARN')
    pg_status = 'FAIL' if pg_fail > 0 else ('WARN' if pg_warn > 0 else 'PASS')
    rows += f'''
    <tr class="pg-header" onclick="toggleGroup('{pg}')">
      <td class="pg-name">▶ {pg}</td>
      <td>{data["desc"]}</td>
      <td colspan="2"><span class="badge badge-pass">{pg_pass} pass</span> <span class="badge badge-warn">{pg_warn} warn</span> <span class="badge badge-fail">{pg_fail} fail</span></td>
      <td><span class="status-pill pill-{pg_status.lower()}">{pg_status}</span></td>
    </tr>'''
    for t in data['tests']:
        s = t['status'].lower()
        icon = '✓' if t['status'] == 'PASS' else ('⚠' if t['status'] == 'WARN' else '✗')
        rows += f'''
    <tr class="test-row group-{pg}" style="display:none">
      <td class="indent">↳ {t["test"]}</td>
      <td colspan="2">{t["detail"]}</td>
      <td></td>
      <td><span class="status-pill pill-{s}">{icon} {t["status"]}</span></td>
    </tr>'''

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>VLAN Test Report — {ts}</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@300;400;600&display=swap');
  :root {{ --bg: #0d1117; --surface: #161b22; --border: #21262d; --text: #c9d1d9; --muted: #8b949e; --pass: #3fb950; --fail: #f85149; --warn: #d29922; --accent: #58a6ff; }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ background: var(--bg); color: var(--text); font-family: 'IBM Plex Sans', sans-serif; font-size: 14px; line-height: 1.6; padding: 40px; }}
  header {{ border-bottom: 1px solid var(--border); padding-bottom: 24px; margin-bottom: 32px; display: flex; justify-content: space-between; align-items: flex-end; }}
  header h1 {{ font-family: 'IBM Plex Mono', monospace; font-size: 22px; font-weight: 600; color: #fff; letter-spacing: -0.5px; }}
  header .meta {{ font-family: 'IBM Plex Mono', monospace; font-size: 11px; color: var(--muted); text-align: right; line-height: 1.8; }}
  .summary {{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 32px; }}
  .stat-card {{ background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 20px 24px; }}
  .stat-card .label {{ font-size: 11px; text-transform: uppercase; letter-spacing: 1px; color: var(--muted); margin-bottom: 6px; font-family: 'IBM Plex Mono', monospace; }}
  .stat-card .value {{ font-size: 32px; font-weight: 600; font-family: 'IBM Plex Mono', monospace; }}
  .stat-card.s-pass .value {{ color: var(--pass); }} .stat-card.s-fail .value {{ color: var(--fail); }} .stat-card.s-warn .value {{ color: var(--warn); }} .stat-card.s-total .value {{ color: var(--accent); }}
  table {{ width: 100%; border-collapse: collapse; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }}
  thead th {{ background: #1c2128; font-family: 'IBM Plex Mono', monospace; font-size: 11px; text-transform: uppercase; letter-spacing: 1px; color: var(--muted); padding: 12px 16px; text-align: left; border-bottom: 1px solid var(--border); }}
  td {{ padding: 11px 16px; border-bottom: 1px solid var(--border); vertical-align: middle; }}
  tr:last-child td {{ border-bottom: none; }}
  .pg-header {{ cursor: pointer; background: #1c2128; }} .pg-header:hover {{ background: #21262d; }}
  .pg-name {{ font-family: 'IBM Plex Mono', monospace; font-weight: 600; color: var(--accent); font-size: 13px; }}
  .indent {{ font-family: 'IBM Plex Mono', monospace; font-size: 12px; color: var(--muted); padding-left: 32px; }}
  .test-row {{ background: var(--bg); }} .test-row td {{ font-size: 13px; }}
  .status-pill {{ display: inline-block; padding: 2px 10px; border-radius: 20px; font-family: 'IBM Plex Mono', monospace; font-size: 11px; font-weight: 600; letter-spacing: 0.5px; }}
  .pill-pass {{ background: rgba(63,185,80,0.15); color: var(--pass); border: 1px solid rgba(63,185,80,0.3); }}
  .pill-fail {{ background: rgba(248,81,73,0.15); color: var(--fail); border: 1px solid rgba(248,81,73,0.3); }}
  .pill-warn {{ background: rgba(210,153,34,0.15); color: var(--warn); border: 1px solid rgba(210,153,34,0.3); }}
  .badge {{ display: inline-block; padding: 1px 7px; border-radius: 4px; font-size: 11px; font-family: 'IBM Plex Mono', monospace; margin-right: 4px; }}
  .badge-pass {{ background: rgba(63,185,80,0.1); color: var(--pass); }} .badge-fail {{ background: rgba(248,81,73,0.1); color: var(--fail); }} .badge-warn {{ background: rgba(210,153,34,0.1); color: var(--warn); }}
  footer {{ margin-top: 40px; padding-top: 20px; border-top: 1px solid var(--border); font-size: 11px; color: var(--muted); font-family: 'IBM Plex Mono', monospace; text-align: center; }}
</style>
</head>
<body>
<header>
  <div><h1>⬡ vSphere VLAN Test Report</h1><div style="color:var(--muted);font-size:13px;margin-top:4px;">VM: $VM_NAME</div></div>
  <div class="meta">Generated: {ts}<br>VLANs tested: {len(groups)}<br>Total checks: {total}</div>
</header>
<div class="summary">
  <div class="stat-card s-total"><div class="label">Total Checks</div><div class="value">{total}</div></div>
  <div class="stat-card s-pass"><div class="label">Passed</div><div class="value">{pass_c}</div></div>
  <div class="stat-card s-warn"><div class="label">Warnings</div><div class="value">{warn_c}</div></div>
  <div class="stat-card s-fail"><div class="label">Failed</div><div class="value">{fail_c}</div></div>
</div>
<table>
  <thead><tr><th>Port Group / Test</th><th>Description</th><th colspan="2">Detail</th><th>Status</th></tr></thead>
  <tbody>{rows}</tbody>
</table>
<footer>vlan-test.sh &nbsp;·&nbsp; {ts} &nbsp;·&nbsp; click port group rows to expand tests</footer>
<script>
function toggleGroup(pg) {{
  const rows = document.querySelectorAll('.group-' + pg);
  const header = document.querySelector('[onclick="toggleGroup(\\'' + pg + '\\')"] td.pg-name');
  const visible = rows[0] && rows[0].style.display !== 'none';
  rows.forEach(r => r.style.display = visible ? 'none' : 'table-row');
  if (header) header.textContent = (visible ? '▶ ' : '▼ ') + pg;
}}
</script>
</body></html>"""

with open("$HTML_FILE", "w") as f:
    f.write(html)
PYEOF

log "HTML report saved: $HTML_FILE"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║              Test Complete               ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  ✓ PASS  : $PASS_COUNT"
echo "  ⚠ WARN  : $WARN_COUNT"
echo "  ✗ FAIL  : $FAIL_COUNT"
echo ""
echo "  JSON   → $JSON_FILE"
echo "  Report → $HTML_FILE"
echo ""
