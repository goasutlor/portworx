#!/usr/bin/env bash
# ==============================================================================
# SCRIPT: px-house-keeping.sh
# VERSION: 1.0.06022026
# AUTHOR: Sontas Jiamsripong
# LOGIC:  Clean up Released PVs and Orphaned Portworx Volumes (for Retain policy)
# USAGE:  ./px-house-keeping.sh [namespace]
#         namespace defaults to first found (portworx-cwdc, portworx-tls2, portworx, kube-system)
# ==============================================================================

set -o pipefail
export TZ="${TZ:-Asia/Bangkok}"

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Optional: audit log (set LOG_DIR to enable)
LOG_DIR="${LOG_DIR:-}"
LOG_FILE=""
[[ -n "$LOG_DIR" ]] && { mkdir -p "$LOG_DIR"; LOG_FILE="$LOG_DIR/px-housekeeping_$(date '+%Y%m%d').log"; }
log() { echo -e "$@"; [[ -n "$LOG_FILE" ]] && echo -e "$@" >> "$LOG_FILE"; }

# Temp file cleanup on exit
SCAN_RESULT=""
cleanup() { [[ -n "$SCAN_RESULT" && -f "$SCAN_RESULT" ]] && rm -f "$SCAN_RESULT"; }
trap cleanup EXIT

PX_NS="${1:-}"

# Discover Portworx namespace if not provided
get_px_ns() {
    if [[ -n "$PX_NS" ]]; then
        oc get pods -n "$PX_NS" -l name=portworx --no-headers 2>/dev/null | grep -q Running && echo "$PX_NS" && return
    fi
    for ns in portworx-cwdc portworx-tls2 portworx kube-system; do
        oc get pods -n "$ns" -l name=portworx --no-headers 2>/dev/null | grep -q Running && echo "$ns" && return
    done
    oc get pods -A -l name=portworx --no-headers 2>/dev/null | grep Running | awk '{print $1}' | head -n 1
}

get_px_pod() {
    [[ -z "$PX_NS" ]] && PX_NS=$(get_px_ns)
    oc get pods -n "$PX_NS" -l name=portworx --no-headers 2>/dev/null | grep Running | awk '{print $1}' | head -n 1
}

# Function to Print Table
print_table() {
    local data_file=$1
    log "-----------------------------------------------------------------------------------------------------------------------------------------------"
    log "$(printf '%-18s | %-45s | %-32s | %-12s | %-10s' 'Namespace' 'Volume ID / PV Name' 'PVC Name' 'PX Status' 'PV Phase')"
    log "-----------------------------------------------------------------------------------------------------------------------------------------------"

    local curr_ns=""
    while IFS='|' read -r ns pv pvc pxstat phase volid; do
        if [ "$ns" != "$curr_ns" ]; then
            if [ "$ns" == "Z_ORPHANED" ]; then log "${RED}> NAMESPACE: [ ORPHANED / NO OWNER ]${NC}";
            else log "${CYAN}> NAMESPACE: $ns${NC}"; fi
            curr_ns=$ns
        fi

        COLOR=$NC
        if [ "$phase" == "Bound" ]; then COLOR=$GREEN
        elif [ "$phase" == "Released" ]; then COLOR=$YELLOW
        elif [ "$phase" == "Deleted" ]; then COLOR=$RED
        fi
        log "$(printf "${COLOR}  %-16s | %-45s | %-32s | %-12s | %-10s${NC}\n" '-' "$pv" "$pvc" "$pxstat" "$phase")"
    done < <(sort -t'|' -k1 "$data_file")
    log "-----------------------------------------------------------------------------------------------------------------------------------------------"
}

# Function to Scan Resources
run_scan() {
    local PX_POD
    PX_POD=$(get_px_pod)
    if [ -z "$PX_POD" ]; then
        echo -e "${RED}Error: Portworx pod not found in namespace '$PX_NS'.${NC}" >&2
        exit 1
    fi

    local TMPFILE
    TMPFILE=$(mktemp 2>/dev/null || echo "/tmp/px_scan_$$")
    local PV_MAP
    PV_MAP=$(oc get pv -o jsonpath='{range .items[*]}{.metadata.name}{","}{.spec.claimRef.namespace}{","}{.spec.claimRef.name}{","}{.status.phase}{"\n"}{end}' 2>/dev/null)
    local PX_VOLS
    PX_VOLS=$(oc exec -n "$PX_NS" "$PX_POD" -- /opt/pwx/bin/pxctl volume list 2>/dev/null | grep -E "^[0-9]+" | awk '{print $1}')

    for VOL_ID in $PX_VOLS; do
        local VOL_INFO
        VOL_INFO=$(oc exec -n "$PX_NS" "$PX_POD" -- /opt/pwx/bin/pxctl volume inspect "$VOL_ID" 2>/dev/null)
        local PV_NAME
        PV_NAME=$(echo "$VOL_INFO" | grep "Name" | head -n 1 | awk '{print $NF}')
        local PX_STATE
        PX_STATE=$(echo "$VOL_INFO" | grep "State" | head -n 1 | awk '{print $NF}')
        local PV_DATA
        PV_DATA=$(echo "$PV_MAP" | grep "^$PV_NAME,")

        if [ -n "$PV_DATA" ]; then
            local NS PVC PHASE
            NS=$(echo "$PV_DATA" | cut -d',' -f2)
            PVC=$(echo "$PV_DATA" | cut -d',' -f3)
            PHASE=$(echo "$PV_DATA" | cut -d',' -f4)
        else
            NS="Z_ORPHANED"; PVC="-"; PHASE="Deleted"
        fi
        echo "$NS|$PV_NAME|$PVC|$PX_STATE|$PHASE|$VOL_ID" >> "$TMPFILE"
    done
    echo "$TMPFILE"
}

# --- START PROCESS ---
PX_NS=$(get_px_ns)
[[ -z "$PX_NS" ]] && { echo -e "${RED}Error: No Portworx namespace found.${NC}" >&2; exit 1; }

log "${BLUE}Portworx namespace: $PX_NS${NC}"
log "${BLUE}Scanning Portworx Volumes...${NC}"
SCAN_RESULT=$(run_scan)
print_table "$SCAN_RESULT"

# Summary Logic (safe counts; strip newlines so summary and [ ] compare work)
TOTAL=$(wc -l < "$SCAN_RESULT" 2>/dev/null | tr -d '\n\r'); TOTAL=$((TOTAL + 0))
HEALTHY=$(grep -c "|Bound" "$SCAN_RESULT" 2>/dev/null | tr -d '\n\r'); HEALTHY=$((HEALTHY + 0))
RELEASED=$(grep -c "|Released|" "$SCAN_RESULT" 2>/dev/null | tr -d '\n\r'); RELEASED=$((RELEASED + 0))
ORPHAN=$(grep -c "Z_ORPHANED|" "$SCAN_RESULT" 2>/dev/null | tr -d '\n\r'); ORPHAN=$((ORPHAN + 0))

log "${BLUE}AUDIT SUMMARY:${NC}"
log "Total Volumes: $TOTAL | Healthy (Bound): ${GREEN}$HEALTHY${NC} | Released (Ghost): ${YELLOW}$RELEASED${NC} | Orphaned (No PV): ${RED}$ORPHAN${NC}"

# --- Phase 1: Cleanup Released PVs ---
if [ "$RELEASED" -gt 0 ]; then
    log "\n${YELLOW}WARNING: Deleting Released PVs will remove the last K8s reference to the data.${NC}"
    read -p "Delete ALL $RELEASED Released PVs? (y/n): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        for pv in $(grep "|Released|" "$SCAN_RESULT" | cut -d'|' -f2); do
            log "Deleting PV: $pv"
            oc delete pv "$pv" --timeout=15s 2>/dev/null || true
        done
        log "${GREEN}PV Cleanup done. Rescanning system for Orphans...${NC}"
        sleep 3
        rm -f "$SCAN_RESULT"
        SCAN_RESULT=$(run_scan)
        log "${BLUE}Updated Status After PV Deletion:${NC}"
        print_table "$SCAN_RESULT"
        ORPHAN=$(grep -c "Z_ORPHANED|" "$SCAN_RESULT" 2>/dev/null | tr -d '\n\r'); ORPHAN=$((ORPHAN + 0))
    fi
fi

# --- Phase 2: Cleanup Orphaned Volumes ---
if [ "$ORPHAN" -gt 0 ]; then
    log "\n${RED}CRITICAL WARNING: Force deleting Portworx volumes is PERMANENT and IRREVERSIBLE.${NC}"
    read -p "Delete ALL $ORPHAN Orphaned PX Volumes? (y/n): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        PX_POD=$(get_px_pod)
        for volid in $(grep "Z_ORPHANED|" "$SCAN_RESULT" | cut -d'|' -f6); do
            log "${RED}Force Deleting PX Volume: $volid${NC}"
            oc exec -n "$PX_NS" "$PX_POD" -- /opt/pwx/bin/pxctl volume detach "$volid" 2>/dev/null || true
            oc exec -n "$PX_NS" "$PX_POD" -- /opt/pwx/bin/pxctl volume delete --force "$volid" 2>/dev/null || true
        done
        log "${GREEN}Orphaned Volumes cleanup finished.${NC}"
    fi
else
    log "\n${GREEN}No Orphaned Volumes found for deletion.${NC}"
fi

log "${BLUE}Housekeeping Process Finished.${NC}"
if [[ -n "$LOG_FILE" ]]; then
    log "Log written to: $LOG_FILE"
fi
