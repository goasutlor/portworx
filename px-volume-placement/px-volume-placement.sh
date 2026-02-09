#!/usr/bin/env bash
# ==============================================================================
# SCRIPT: px-volume-placement.sh
# VERSION: 1.0.06022026
# AUTHOR: Sontas Jiamsripong
# PURPOSE: Scan PVCs by StorageClass, analyze replica placement vs Pod host,
#          and organize volumes so replicas align with Pod nodes (reduce latency).
# PREREQUISITE: Run "oc login" to OpenShift cluster BEFORE running this script.
# USAGE: ./px-volume-placement.sh
#        StorageClass is selectable at runtime (not hardcoded).
# ==============================================================================
# Strategy for Rep=2: Expand to Rep=3 (add replica on Pod's node), then remove
# replica from a node that is NOT the Pod's host. Result: at least 1 replica local.
# Balance concern: Manual placement may skew pool utilization; script shows pool
# state and imbalance metrics before/after actions.
# ==============================================================================

set -o pipefail
export TZ="${TZ:-Asia/Bangkok}"

# --- Pre-flight: oc login required ---
if ! oc whoami &>/dev/null; then
    echo "ERROR: Not logged in to OpenShift."
    echo "Please run: oc login <cluster-url>"
    exit 1
fi

# ANSI
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; C='\033[0;36m'; M='\033[0;35m'; NC='\033[0m'

# Optional log
LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/px-volume-placement_$(date '+%Y%m%d').log"
log() { echo -e "$@"; echo -e "$@" >> "$LOG_FILE" 2>/dev/null || true; }

# Temp cleanup (only on exit, not during run)
cleanup() {
    [[ -n "$SCAN_FILE" && -f "$SCAN_FILE" ]] && rm -f "$SCAN_FILE" 2>/dev/null || true
    rm -f /tmp/px_vp_$$.* 2>/dev/null || true
}
trap cleanup EXIT

# --- Discover Portworx ---
get_px_ns() {
    for ns in portworx-cwdc portworx-tls2 portworx kube-system; do
        oc get pods -n "$ns" -l name=portworx --no-headers 2>/dev/null | grep -q Running && echo "$ns" && return
    done
    oc get pods -A -l name=portworx --no-headers 2>/dev/null | grep Running | awk '{print $1}' | head -n 1
}
get_px_pod() {
    local ns="${1:-$PX_NS}"
    oc get pods -n "$ns" -l name=portworx --no-headers 2>/dev/null | grep Running | awk '{print $1}' | head -n 1
}

# --- StorageClass selection ---
select_storage_class() {
    local list
    list=$(oc get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    if [[ -z "$list" ]]; then
        log "${R}No StorageClasses found.${NC}"
        return 1
    fi
    local arr=(); while read -r l; do [[ -n "$l" ]] && arr+=("$l"); done <<< "$list"
    log "${C}StorageClasses:${NC}"
    for i in "${!arr[@]}"; do
        log "  $((i+1))) ${arr[$i]}"
    done
    log "  0) Cancel (keep current)"
    read -p "Select SC number (Enter=first, 0=cancel): " choice < /dev/tty
    [[ "$choice" == "0" || "$choice" =~ ^[bB]$ ]] && { log "${Y}Cancelled.${NC}"; return 1; }
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#arr[@]} ]]; then
        PX_SC="${arr[$((choice-1))]}"
        log "${G}Selected: $PX_SC${NC}"
        return 0
    fi
    log "${Y}Invalid. Cancelled.${NC}"
    return 1
}

# --- Get K8s node InternalIP from node name ---
node_to_ip() {
    local node="$1"
    oc get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null
}

# --- Get PX Node ID from IP (Portworx 3.5 ha-update requires Node ID or Pool UUID, not IP) ---
ip_to_node_id() {
    local ip="$1"
    local raw
    raw=$(oc exec -n "$PX_NS" "$PX_POD" -- pxctl cluster list 2>/dev/null)
    # pxctl cluster list: column 1=Node ID (UUID), column 2=DATA IP
    echo "$raw" | awk -v ip="$ip" '
        $2 == ip && $1 ~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/ { print $1; exit }
    '
}

# --- Get PVCs for selected SC ---
get_pvcs_for_sc() {
    timeout 30 oc get pvc -A -o json 2>/dev/null | timeout 10 jq -r --arg sc "$PX_SC" '
        .items[] | select(.spec.storageClassName == $sc or (.spec.storageClassName == null and $sc == ""))
        | "\(.metadata.namespace)|\(.metadata.name)|\(.spec.volumeName)"
    ' 2>/dev/null | grep -v '^$' || true
}

# --- For a PVC (ns, name), find Pod(s) using it and their node ---
get_pod_node_for_pvc() {
    local ns="$1" pvc="$2"
    local pod_json
    pod_json=$(oc get pods -n "$ns" -o json 2>/dev/null)
    local node
    node=$(echo "$pod_json" | jq -r --arg ns "$ns" --arg pvc "$pvc" '
        .items[] | select(.status.phase=="Running") |
        . as $p |
        .spec.volumes[]? | select(.persistentVolumeClaim.claimName? == $pvc) |
        $p.spec.nodeName // empty
    ' 2>/dev/null | head -n 1)
    echo "$node"
}

# --- Get volume replica node IPs from pxctl inspect ---
get_replica_ips() {
    local vol_id="$1"
    local raw
    raw=$(timeout 10 oc exec -n "$PX_NS" "$PX_POD" -- pxctl volume inspect "$vol_id" 2>/dev/null)
    echo "$raw" | sed -n '/Replica sets on nodes:/,/Replication Status/p' | grep "Node " | awk -F': ' '{print $2}' | xargs
}

# --- Get volume replication factor (Rep = number of replicas) ---
get_volume_rep() {
    local vol_id="$1"
    local ha
    ha=$(timeout 10 oc exec -n "$PX_NS" "$PX_POD" -- pxctl volume inspect "$vol_id" 2>/dev/null | grep -E "^HA " | grep -oE "[0-9]+" | head -n 1)
    [[ -n "$ha" ]] && echo "$ha" && return
    local reps
    reps=$(get_replica_ips "$vol_id")
    echo "$reps" | wc -w
}

# --- Run placement scan ---
run_scan() {
    local tmp="/tmp/px_vp_$$_scan"
    : > "$tmp"
    if [[ ! -f "$tmp" ]]; then
        echo -e "${R}Error: Cannot create temp file $tmp${NC}" >&2
        return 1
    fi
    echo -e "${C}Fetching PVCs for StorageClass: $PX_SC...${NC}" >&2
    local pvcs
    pvcs=$(get_pvcs_for_sc)
    if [[ -z "$pvcs" ]]; then
        echo -e "${Y}No PVCs found for StorageClass: $PX_SC${NC}" >&2
        echo "$tmp"
        return
    fi
    local total=$(echo "$pvcs" | wc -l)
    echo -e "${C}Found $total PVC(s). Scanning placement...${NC}" >&2
    local idx=0
    while IFS='|' read -r ns pvc vol_id; do
        [[ -z "$vol_id" || "$vol_id" == "null" ]] && continue
        ((idx++))
        echo -ne "\r${C}[$idx/$total] $ns/$pvc...${NC}" >&2
        local pod_node
        pod_node=$(get_pod_node_for_pvc "$ns" "$pvc")
        local pod_ip=""
        [[ -n "$pod_node" ]] && pod_ip=$(node_to_ip "$pod_node")
        # Try to inspect volume (skip non-PX volumes like NFS)
        local vol_inspect
        vol_inspect=$(timeout 10 oc exec -n "$PX_NS" "$PX_POD" -- pxctl volume inspect "$vol_id" 2>&1)
        if echo "$vol_inspect" | grep -qE "(not found|does not exist|Invalid volume)" || [[ -z "$vol_inspect" ]]; then
            # Not a Portworx volume (e.g. NFS CSI) - skip detailed scan
            echo "$idx|$ns|$pvc|$vol_id|$pod_node|$pod_ip||0|NO_PX" >> "$tmp"
            continue
        fi
        local replica_ips
        replica_ips=$(echo "$vol_inspect" | sed -n '/Replica sets on nodes:/,/Replication Status/p' | grep "Node " | awk -F': ' '{print $2}' | xargs)
        local rep
        rep=$(echo "$vol_inspect" | grep -E "^HA " | grep -oE "[0-9]+" | head -n 1)
        [[ -z "$rep" ]] && rep=$(echo $replica_ips | wc -w)
        rep="${rep:-1}"
        local status="REMOTE"
        if [[ -n "$pod_ip" ]]; then
            if echo " $replica_ips " | grep -q " $pod_ip "; then
                status="LOCAL"
            fi
        else
            status="NO_POD"
        fi
        echo "$idx|$ns|$pvc|$vol_id|$pod_node|$pod_ip|$replica_ips|$rep|$status" >> "$tmp"
    done <<< "$pvcs"
    echo "" >&2  # New line after progress
    # Verify temp file exists and has content
    if [[ ! -f "$tmp" ]]; then
        echo -e "${R}Error: Temp file $tmp was deleted!${NC}" >&2
        return 1
    fi
    # Ensure file is readable
    if [[ ! -r "$tmp" ]]; then
        echo -e "${R}Error: Temp file $tmp is not readable!${NC}" >&2
        return 1
    fi
    # Verify file has content (at least one line)
    local line_count=$(wc -l < "$tmp" 2>/dev/null || echo "0")
    if [[ "$line_count" -eq 0 ]]; then
        echo -e "${Y}Warning: Temp file $tmp is empty.${NC}" >&2
    fi
    # Return absolute path (must be on stdout, not stderr)
    echo "$tmp"
}

# --- Print scan table ---
print_scan_table() {
    local f="$1"
    log ""
    log "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${B}SC: $PX_SC | PX: $PX_NS${NC}"
    log "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "$(printf '%-4s %-4s %-18s %-26s %-24s %-5s %-8s %s' 'ID' 'SEL' 'NAMESPACE' 'PVC' 'POD_NODE' 'Rep' 'PLACEMENT' 'REPLICAS')"
    log "--------------------------------------------------------------------------------"
    local curr_ns=""
    while IFS='|' read -r idx ns pvc vol_id pod_node pod_ip replica_ips rep status; do
        [[ -z "$idx" ]] && continue
        rep="${rep:-?}"
        if [[ "$ns" != "$curr_ns" ]]; then
            log "${C}-- Namespace: $ns --${NC}"
            curr_ns="$ns"
        fi
        local sel="${SEL_MAP[$idx]:- }"
        [[ -z "$sel" ]] && sel=" "
        local col="$NC"
        [[ "$status" == "LOCAL" ]] && col="$G"
        [[ "$status" == "REMOTE" ]] && col="$R"
        [[ "$status" == "NO_POD" ]] && col="$Y"
        [[ "$status" == "NO_PX" ]] && col="$M"
        local pvc_short="${pvc:0:24}"
        local pod_display="${pod_node:0:24}"
        local reps_short="${replica_ips:0:30}"
        log "$(printf "%-4s [%s]  %-18s %-26s %-24s %-5s ${col}%-8s${NC} %s" "$idx" "$sel" "$ns" "$pvc_short" "$pod_display" "$rep" "$status" "$reps_short")"
    done < "$f" 2>/dev/null
    log "--------------------------------------------------------------------------------"
}

# --- Cluster state: show pxctl cluster list (ID, DATA IP, STATUS) ---
show_cluster_state() {
    local raw
    raw=$(oc exec -n "$PX_NS" "$PX_POD" -- pxctl cluster list 2>/dev/null)
    log ""
    log "${B}━━ PX CLUSTER STATE (Storage Nodes) ━━${NC}"
    if [[ -z "$raw" ]]; then
        log "${Y}(No output from pxctl cluster list)${NC}"
    else
        echo "$raw"
        echo "$raw" >> "$LOG_FILE" 2>/dev/null || true
    fi
    log ""
}

# --- Pool balance: show pxctl status (raw) for pool/capacity info ---
show_balance_metric() {
    local raw
    raw=$(oc exec -n "$PX_NS" "$PX_POD" -- pxctl status 2>/dev/null)
    log "${B}Pool balance (manual placement may skew utilization):${NC}"
    if [[ -z "$raw" ]]; then
        log "${Y}(No output from pxctl status)${NC}"
    else
        # Show raw status so user sees pool/capacity info regardless of format
        echo "$raw"
        echo "$raw" >> "$LOG_FILE" 2>/dev/null || true
    fi
    log ""
}

# --- Rescan and show PVC list (after any action: Organize, Increase/Decrease Rep) ---
do_rescan_and_show() {
    log "${G}Waiting 10s for replication to settle, then rescanning...${NC}"
    sleep 10
    SCAN_FILE=$(run_scan)
    if [[ -z "$SCAN_FILE" || ! -f "$SCAN_FILE" ]]; then
        log "${R}Error: Rescan failed.${NC}"
        return 1
    fi
    print_scan_table "$SCAN_FILE"
    log "${G}✓ Updated results displayed above.${NC}"
}

# --- Organize: add replica on pod node, remove from non-pod node ---
organize_volume() {
    local vol_id="$1" pod_ip="$2" replica_ips="$3" rep="$4"
    if [[ -z "$pod_ip" ]]; then
        log "${R}Cannot organize: no Pod running (NO_POD).${NC}"
        return 1
    fi
    if echo " $replica_ips " | grep -q " $pod_ip "; then
        log "${G}Volume already has replica on Pod node. Skip.${NC}"
        return 0
    fi
    log "${R}⚠ REMINDER: Organize will add replica on Pod node, then remove from another. Volume briefly becomes Rep=3. Do NOT interrupt.${NC}"
    log ""
    local max_rep=3
    if [[ "$rep" -ge "$max_rep" ]]; then
        log ""
        log "${B}--- Rep=$rep (max $max_rep): Remove replica from non-Pod node to get local ---${NC}"
        local to_remove=""
        for rip in $replica_ips; do
            [[ "$rip" != "$pod_ip" ]] && { to_remove="$rip"; break; }
        done
        if [[ -z "$to_remove" ]]; then
            log "${R}Could not determine replica to remove.${NC}"
            return 1
        fi
        log "${Y}Step 1:${NC} Removing replica from node $to_remove (IP)..."
        to_node_id=$(ip_to_node_id "$to_remove"); [[ -z "$to_node_id" ]] && to_node_id="$to_remove"
        log "  Command: pxctl volume ha-update -r $((rep-1)) -n $to_node_id $vol_id"
        oc exec -n "$PX_NS" "$PX_POD" -- pxctl volume ha-update -r $((rep-1)) -n "$to_node_id" "$vol_id" 2>&1 | tee -a "$LOG_FILE"
        sleep 5
        log "${G}Done. Rescan to verify.${NC}"
        log ""
        return 0
    fi
    # rep < 3: add on pod node first, then remove from non-pod
    local new_rep=$((rep+1))
    log ""
    log "${B}--- Rep=$rep: Add replica on Pod node, then remove from non-Pod node (target: Rep=$rep) ---${NC}"
    log ""
    log "${Y}Step 1:${NC} Add replica on Pod node $pod_ip (IP)..."
    pod_node_id=$(ip_to_node_id "$pod_ip"); [[ -z "$pod_node_id" ]] && pod_node_id="$pod_ip"
    log "  Command: pxctl volume ha-update -r $new_rep -n $pod_node_id $vol_id"
    oc exec -n "$PX_NS" "$PX_POD" -- pxctl volume ha-update -r "$new_rep" -n "$pod_node_id" "$vol_id" 2>&1 | tee -a "$LOG_FILE"
    log "  Waiting for replication (30s)..."
    sleep 30
    replica_ips=$(get_replica_ips "$vol_id")
    local to_remove=""
    for rip in $replica_ips; do
        [[ "$rip" != "$pod_ip" ]] && { to_remove="$rip"; break; }
    done
    if [[ -z "$to_remove" ]]; then
        log "${G}Replica added on Pod node. Keeping Rep=$new_rep.${NC}"
        log ""
        return 0
    fi
    log ""
    log "${Y}Step 2:${NC} Remove replica from node $to_remove (IP)..."
    to_node_id=$(ip_to_node_id "$to_remove"); [[ -z "$to_node_id" ]] && to_node_id="$to_remove"
    log "  Command: pxctl volume ha-update -r $rep -n $to_node_id $vol_id"
    oc exec -n "$PX_NS" "$PX_POD" -- pxctl volume ha-update -r "$rep" -n "$to_node_id" "$vol_id" 2>&1 | tee -a "$LOG_FILE"
    sleep 5
    log "${G}Done. Rep=$rep with replica on Pod node. Rescan to verify.${NC}"
    log ""
    return 0
}

# --- Get node IPs (from oc, works on OpenShift) ---
get_node_ips() {
    oc get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"
}

# --- Increase Rep: add replica on target node ---
increase_rep() {
    local vol_id="$1" rep="$2" target_node="$3" ns="$4" pvc="$5" replica_ips="$6"
    # Target node MUST NOT already have a replica (Portworx limit: 1 replica per node)
    if echo " $replica_ips " | grep -q " $target_node "; then
        log "${R}Node $target_node already has a replica. Choose a different node (Portworx allows only 1 replica per node).${NC}"
        return 1
    fi
    local new_rep=$((rep+1))
    if [[ "$new_rep" -gt 3 ]]; then
        log "${R}Max Rep=3. Cannot increase.${NC}"
        return 1
    fi
    log ""
    log "${R}⚠ REMINDER: Manual replica placement may skew pool utilization. Check pool balance after.${NC}"
    log ""
    log "${B}--- Increase Rep: $ns/$pvc (Rep $rep -> $new_rep) ---${NC}"
    log "${Y}Step:${NC} Add replica on node $target_node (IP)"
    # Portworx 3.5 ha-update requires Node ID or Pool UUID, not IP
    local node_id
    node_id=$(ip_to_node_id "$target_node")
    if [[ -z "$node_id" ]]; then
        log "${Y}Trying IP directly (some versions accept IP)...${NC}"
        node_id="$target_node"
    else
        log "  PX Node ID: $node_id"
    fi
    log "  → Rep $rep -> $new_rep. Ensures additional copy on target node."
    log "  Command: pxctl volume ha-update -r $new_rep -n $node_id $vol_id"
    local out
    out=$(oc exec -n "$PX_NS" "$PX_POD" -- pxctl volume ha-update -r "$new_rep" -n "$node_id" "$vol_id" 2>&1)
    local rc=$?
    echo "$out" | tee -a "$LOG_FILE"
    if [[ $rc -ne 0 ]]; then
        log "${R}FAILED (exit $rc). Check error above. Common: node ID format, volume attached, licence.${NC}"
        log ""
        return 1
    fi
    sleep 5
    log "${G}SUCCESS. Rep=$new_rep. Rescan to verify.${NC}"
    log ""
}

# --- Decrease Rep: remove replica from specified node ---
decrease_rep() {
    local vol_id="$1" rep="$2" node_to_remove="$3" ns="$4" pvc="$5"
    local new_rep=$((rep-1))
    if [[ "$new_rep" -lt 1 ]]; then
        log "${R}Rep cannot go below 1.${NC}"
        return 1
    fi
    log ""
    log "${R}⚠ REMINDER: Removing replica reduces redundancy. Operation cannot be undone for that copy.${NC}"
    if [[ "$new_rep" -eq 1 ]]; then
        log "${R}⚠ Rep=1 = NO HA. Pod may go down if this node fails. High risk.${NC}"
        read -p "Continue? (y/n): " confirm < /dev/tty
        [[ ! "$confirm" =~ ^[Yy]$ ]] && log "Aborted." && return 0
    fi
    log ""
    log "${B}--- Decrease Rep: $ns/$pvc (Rep $rep -> $new_rep) ---${NC}"
    log "${Y}Step:${NC} Remove replica from node $node_to_remove (IP)"
    local node_id
    node_id=$(ip_to_node_id "$node_to_remove")
    [[ -z "$node_id" ]] && node_id="$node_to_remove"
    log "  Command: pxctl volume ha-update -r $new_rep -n $node_id $vol_id"
    oc exec -n "$PX_NS" "$PX_POD" -- pxctl volume ha-update -r "$new_rep" -n "$node_id" "$vol_id" 2>&1 | tee -a "$LOG_FILE"
    sleep 5
    log "${G}Done. Rep=$new_rep. Rescan to verify.${NC}"
    log ""
}

# --- Toggle selection ---
toggle_selection() {
    [[ -z "$SCAN_FILE" || ! -f "$SCAN_FILE" ]] && return
    read -p "Enter ID(s) to toggle (e.g. 1 3 5), 'a' for all, 'b' to cancel: " input < /dev/tty
    [[ -z "$input" || "$input" =~ ^[bBqQ]$ ]] && { log "${Y}Cancelled.${NC}"; return; }
    local selected=() deselected=()
    if [[ "$input" == "a" ]]; then
        while IFS='|' read -r idx ns pvc rest; do
            [[ -z "$idx" || ! "$idx" =~ ^[0-9]+$ ]] && continue
            if [[ "${SEL_MAP[$idx]}" == "x" ]]; then
                SEL_MAP[$idx]=""
                deselected+=("$idx")
            else
                SEL_MAP[$idx]="x"
                selected+=("$idx")
            fi
        done < "$SCAN_FILE"
    else
        for id in $input; do
            [[ "$id" =~ ^[0-9]+$ ]] || continue
            grep -q "^${id}|" "$SCAN_FILE" 2>/dev/null || continue
            if [[ "${SEL_MAP[$id]}" == "x" ]]; then
                SEL_MAP[$id]=""
                deselected+=("$id")
            else
                SEL_MAP[$id]="x"
                selected+=("$id")
            fi
        done
    fi
    [[ ${#selected[@]} -gt 0 ]] && log "${G}✓ Selected (${#selected[@]}): ${selected[*]}${NC}"
    [[ ${#deselected[@]} -gt 0 ]] && log "${Y}○ Deselected (${#deselected[@]}): ${deselected[*]}${NC}"
    [[ ${#selected[@]} -eq 0 && ${#deselected[@]} -eq 0 ]] && log "${Y}No change.${NC}"
}

# --- Main ---
PX_NS=$(get_px_ns)
if [[ -z "$PX_NS" ]]; then
    log "${R}Portworx namespace not found.${NC}"
    exit 1
fi
PX_POD=$(get_px_pod "$PX_NS")
if [[ -z "$PX_POD" ]]; then
    log "${R}Portworx pod not found.${NC}"
    exit 1
fi

# StorageClass: env override or prompt to select (must pick Portworx SC, not nfs-csi etc.)
if [[ -n "${PX_SC:-}" ]]; then
    log "${G}Using StorageClass: $PX_SC${NC}"
else
    select_storage_class || exit 1
fi

# Check jq
if ! command -v jq &>/dev/null; then
    log "${R}jq is required. Install: yum install jq / apt install jq${NC}"
    exit 1
fi

declare -A SEL_MAP
SCAN_FILE=""

# Initial rescan: show only PVC list
SCAN_FILE=$(run_scan)
if [[ -z "$SCAN_FILE" ]]; then
    log "${R}Error: Scan failed - no temp file returned.${NC}"
    exit 1
fi
# Debug: verify file exists immediately after assignment
if [[ ! -f "$SCAN_FILE" ]]; then
    log "${R}Error: Scan failed - temp file missing: $SCAN_FILE${NC}"
    log "${Y}Debug: Checking /tmp/px_vp_$$_scan...${NC}"
    ls -la "/tmp/px_vp_$$_scan" 2>&1 || true
    exit 1
fi
print_scan_table "$SCAN_FILE"

while true; do
    log ""
    log "${M}=== px-volume-placement ===${NC}"
    log "[1] Rescan"
    log "[2] Cluster state"
    log "[3] Pool balance"
    log "[4] Select PVCs"
    log "[5] Organize selected (move replicas to Pod node)"
    log "[6] Change StorageClass"
    log "[7] Increase Rep (add replica on node)"
    log "[8] Decrease Rep (remove replica from node)"
    log "[b] Back (refresh view)"
    log "[q] Quit"
    read -p "Choice: " choice
    case "$choice" in
        1)
            SCAN_FILE=$(run_scan)
            if [[ -z "$SCAN_FILE" || ! -f "$SCAN_FILE" ]]; then
                log "${R}Error: Rescan failed.${NC}"
            else
                print_scan_table "$SCAN_FILE"
            fi
            ;;
        2) show_cluster_state ;;
        3) show_balance_metric ;;
        4)
            if [[ -z "$SCAN_FILE" || ! -f "$SCAN_FILE" ]]; then
                log "${Y}Run [1] Rescan first.${NC}"
            else
                toggle_selection
            fi
            ;;
        5)
            if [[ -z "$SCAN_FILE" || ! -f "$SCAN_FILE" ]]; then
                log "${Y}Run [1] Rescan first.${NC}"
            else
                log "${R}⚠ Organize will move replicas. Volume briefly Rep+1 then back. Do not interrupt.${NC}"
                any_sel=false
                while IFS='|' read -r idx ns pvc vol_id pod_node pod_ip replica_ips rep status; do
                    [[ -z "$idx" ]] && continue
                    [[ "${SEL_MAP[$idx]}" != "x" ]] && continue
                    any_sel=true
                    if [[ "$status" != "REMOTE" ]]; then
                        log "${Y}Skipping $ns/$pvc (status=$status)${NC}"
                        continue
                    fi
                    log "${B}Organizing $ns/$pvc (vol=$vol_id, Rep=$rep)...${NC}"
                    organize_volume "$vol_id" "$pod_ip" "$replica_ips" "$rep"
                done < "$SCAN_FILE"
                if [[ "$any_sel" != "true" ]]; then
                    log "${Y}No PVC selected. Use [4] to select.${NC}"
                else
                    do_rescan_and_show
                fi
            fi
            ;;
        6)
            if select_storage_class; then
                SCAN_FILE=$(run_scan)
                if [[ -z "$SCAN_FILE" || ! -f "$SCAN_FILE" ]]; then
                    log "${R}Error: Rescan failed.${NC}"
                    SCAN_FILE=""
                else
                    print_scan_table "$SCAN_FILE"
                fi
            else
                SCAN_FILE=""
            fi
            ;;
        7)
            if [[ -z "$SCAN_FILE" || ! -f "$SCAN_FILE" ]]; then
                log "${Y}Run [1] Rescan first.${NC}"
            else
                log "${R}⚠ Manual replica placement may skew pool utilization. Check balance after.${NC}"
                any_sel=false
                while IFS='|' read -r idx ns pvc vol_id pod_node pod_ip replica_ips rep status; do
                    [[ -z "$idx" ]] && continue
                    [[ "${SEL_MAP[$idx]}" != "x" ]] && continue
                    any_sel=true
                    log "${B}Increase Rep: $ns/$pvc (vol=$vol_id, Rep=$rep)${NC}"
                    log "  Current replicas on: $replica_ips (cannot add on same node)"
                    target_ip=""
                    if [[ -n "$pod_ip" ]] && ! echo " $replica_ips " | grep -q " $pod_ip "; then
                        log "  Pod node $pod_ip (not in replicas) - suitable for new replica"
                        read -p "  Use Pod node $pod_ip? (y/n) [y]: " ans < /dev/tty
                        ans="${ans:-y}"
                        if [[ "$ans" =~ ^[Yy](es)?$ ]] || [[ "$ans" == "1" ]]; then
                            target_ip="$pod_ip"
                        elif [[ "$ans" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                            target_ip="$ans"
                            if echo " $replica_ips " | grep -q " $target_ip "; then
                                log "${R}$target_ip already has replica. Skipped.${NC}"
                                continue
                            fi
                        else
                            log "${Y}Skipped.${NC}"
                            continue
                        fi
                    else
                        # Rep=1 or Pod node already has replica: must pick a different node
                        all_nodes=$(get_node_ips)
                        avail=""
                        for n in $all_nodes; do
                            echo " $replica_ips " | grep -q " $n " || avail="$avail $n"
                        done
                        avail=$(echo "$avail" | xargs)
                        if [[ -z "$avail" ]]; then
                            log "${R}No other nodes available. Cannot increase Rep.${NC}"
                            continue
                        fi
                        avail_arr=($avail)
                        if [[ ${#avail_arr[@]} -eq 1 ]]; then
                            # Only 1 node: auto-suggest, Enter = use it
                            log "  Available node: $avail"
                            read -p "  Add replica on $avail? (y/n) [y]: " ans < /dev/tty
                            ans="${ans:-y}"
                            if [[ "$ans" =~ ^[Yy]$ ]]; then
                                target_ip="$avail"
                            else
                                log "${Y}Skipped.${NC}"
                                continue
                            fi
                        else
                            log "  Available nodes (not current replica):"
                            for i in "${!avail_arr[@]}"; do
                                log "    $((i+1))) ${avail_arr[$i]}"
                            done
                            read -p "  Enter number (1-${#avail_arr[@]}) or node IP: " ans < /dev/tty
                            [[ -z "$ans" ]] && { log "${Y}Skipped.${NC}"; continue; }
                            if [[ "$ans" =~ ^[0-9]+$ ]] && [[ "$ans" -ge 1 ]] && [[ "$ans" -le ${#avail_arr[@]} ]]; then
                                target_ip="${avail_arr[$((ans-1))]}"
                            elif [[ "$ans" =~ ^[0-9.]+$ ]]; then
                                target_ip="$ans"
                                if echo " $replica_ips " | grep -q " $target_ip "; then
                                    log "${R}$target_ip already has replica. Skipped.${NC}"
                                    continue
                                fi
                            else
                                log "${Y}Skipped.${NC}"
                                continue
                            fi
                        fi
                    fi
                    increase_rep "$vol_id" "$rep" "$target_ip" "$ns" "$pvc" "$replica_ips"
                done < "$SCAN_FILE"
                if [[ "$any_sel" != "true" ]]; then
                    log "${Y}No PVC selected. Use [4] to select.${NC}"
                else
                    do_rescan_and_show
                fi
            fi
            ;;
        8)
            if [[ -z "$SCAN_FILE" || ! -f "$SCAN_FILE" ]]; then
                log "${Y}Run [1] Rescan first.${NC}"
            else
                log "${R}⚠ Decrease Rep removes replica. Rep=1 = NO HA. Confirm before proceeding.${NC}"
                any_sel=false
                while IFS='|' read -r idx ns pvc vol_id pod_node pod_ip replica_ips rep status; do
                    [[ -z "$idx" ]] && continue
                    [[ "${SEL_MAP[$idx]}" != "x" ]] && continue
                    any_sel=true
                    if [[ "$rep" -le 1 ]]; then
                        log "${Y}Skipping $ns/$pvc: Rep=$rep (already minimum).${NC}"
                        continue
                    fi
                    log "${B}Decrease Rep: $ns/$pvc (vol=$vol_id, Rep=$rep, replicas: $replica_ips)${NC}"
                    read -p "  Enter node IP to REMOVE replica from: " remove_ip < /dev/tty
                    [[ -z "$remove_ip" ]] && { log "${Y}Skipped.${NC}"; continue; }
                    if ! echo " $replica_ips " | grep -q " $remove_ip "; then
                        log "${R}$remove_ip is not a replica node. Skipped.${NC}"
                        continue
                    fi
                    decrease_rep "$vol_id" "$rep" "$remove_ip" "$ns" "$pvc"
                done < "$SCAN_FILE"
                if [[ "$any_sel" != "true" ]]; then
                    log "${Y}No PVC selected. Use [4] to select.${NC}"
                else
                    do_rescan_and_show
                fi
            fi
            ;;
        b|B)
            print_scan_table "$SCAN_FILE"
            ;;
        q|Q) log "Bye."; exit 0 ;;
        *) log "${Y}Invalid.${NC}" ;;
    esac
done
