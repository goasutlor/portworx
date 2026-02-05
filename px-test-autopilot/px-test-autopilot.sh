#!/bin/bash

# ==============================================================================
# PX-ALERT-MONITOR: Portworx Volume and Autopilot Tracking Tool
# Purpose: Monitor Portworx PVCs, Replica health, and Autopilot transitions
# Optional env: PX_NS (default portworx-cwdc), PX_FS_WARN_PCT (default 50), PX_NO_BLINK=1 to disable blink
# ==============================================================================

# Remark: Detect current active namespace or fallback to default
CURRENT_NS=$(oc project -q 2>/dev/null)
PX_NS="${PX_NS:-portworx-cwdc}"  # Override with env if needed

# Optional: FS usage % to trigger alert (default 50); set PX_NO_BLINK=1 to disable blink
PX_FS_WARN_PCT="${PX_FS_WARN_PCT:-50}"
PX_NO_BLINK="${PX_NO_BLINK:-0}"

# Unique temp prefix to avoid collision when multiple instances run
TMP_PREFIX="/tmp/px_monitor_$$"

# --- Function: Select AutopilotRules ---
select_rules() {
    clear
    echo "------------------------------------------------"
    echo " Step 1: Select AutopilotRules to Monitor"
    echo "------------------------------------------------"
    rule_list=($(oc get autopilotrule -o jsonpath='{.items[*].metadata.name}' 2>/dev/null))
    if [ ${#rule_list[@]} -eq 0 ]; then
        echo "No AutopilotRules found. You can continue; rule section will be empty."
        SELECTED_RULES=()
        read -p "Press Enter to continue..."
        return
    fi
    for i in "${!rule_list[@]}"; do echo "$((i+1))) ${rule_list[$i]}"; done
    read -p "Enter selections (e.g. 1 2): " rule_choices
    SELECTED_RULES=()
    for choice in $rule_choices; do
        [[ "$choice" =~ ^[0-9]+$ ]] || continue
        idx=$((choice-1))
        [[ $idx -ge 0 && $idx -lt ${#rule_list[@]} ]] && SELECTED_RULES+=("${rule_list[$idx]}")
    done
}

# --- Function: Select Target Pod and Inspect Volume ---
select_target() {
    clear
    echo "------------------------------------------------"
    echo " Step 2: Select App Pod in Project: $CURRENT_NS"
    echo "------------------------------------------------"
    pod_list=($(oc get pods -n "$CURRENT_NS" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'))
    if [ ${#pod_list[@]} -eq 0 ]; then echo "No pods found."; exit 1; fi
    for i in "${!pod_list[@]}"; do echo "$((i+1))) ${pod_list[$i]}"; done
    read -p "Select Pod Number: " pod_choice
    if ! [[ "$pod_choice" =~ ^[0-9]+$ ]] || [ "$pod_choice" -lt 1 ] || [ "$pod_choice" -gt ${#pod_list[@]} ]; then
        echo "Invalid selection. Using 1."
        pod_choice=1
    fi
    POD_NAME="${pod_list[$((pod_choice-1))]}"

    # Extract PVC and Volume details
    PVC_NAME=$(oc get pod "$POD_NAME" -n "$CURRENT_NS" -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}' | awk '{print $1}')
    VOL_ID=$(oc get pvc "$PVC_NAME" -n "$CURRENT_NS" -o jsonpath='{.spec.volumeName}')
    VOL_REF_NAME=$(oc get pod "$POD_NAME" -n "$CURRENT_NS" -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim.claimName=="'$PVC_NAME'")].name}')
    TARGET_PATH=$(oc get pod "$POD_NAME" -n "$CURRENT_NS" -o jsonpath='{.spec.containers[*].volumeMounts[?(@.name=="'$VOL_REF_NAME'")].mountPath}')

    # Identify any Portworx pod to run pxctl commands
    ANY_PX_POD=$(oc get pods -n "$PX_NS" -l name=portworx -o jsonpath='{.items[0].metadata.name}')
    
    # Store Volume Inspection data for the loop
    INSPECT_DATA=$(oc exec "$ANY_PX_POD" -n "$PX_NS" -- pxctl volume inspect "$VOL_ID")
    
    # Extract Replica IPs for the Summary section
    REPLICA_IPS=$(echo "$INSPECT_DATA" | sed -n '/Replica sets on nodes:/,$p' | grep "Node" | awk -F': ' '{print $2}' | xargs)
}

# --- Function: Generate Workload Load ---
gen_load() {
    tput cnorm
    echo -e "\n>>> Generate Load Configuration <<<"
    read -p "Enter Workload size (GB): " LOAD_GB
    if ! [[ "$LOAD_GB" =~ ^[0-9]+$ ]] || [ "$LOAD_GB" -lt 1 ]; then
        echo "Invalid size. Using 1 GB."
        LOAD_GB=1
    fi
    rm -f "${TMP_PREFIX}_load_log" "${TMP_PREFIX}_dd_pid"
    FILE_ID=$(date +%H%M%S)
    FILE_NAME="test-$FILE_ID"
    # Execute dd inside the pod to consume space
    oc exec -n "$CURRENT_NS" "$POD_NAME" -- sh -c "dd if=/dev/zero of=$TARGET_PATH/$FILE_NAME bs=1G count=$LOAD_GB status=progress" > "${TMP_PREFIX}_load_log" 2>&1 &
    echo $! > "${TMP_PREFIX}_dd_pid"
    echo "Load Started! (File: $FILE_NAME)"
    sleep 1; clear; tput civis
}

# --- Function: Cleanup Test Files ---
clear_data() {
    tput cnorm; echo -e "\n>>> Clearing all test files... <<<"
    oc exec -n "$CURRENT_NS" "$POD_NAME" -- sh -c "rm -f $TARGET_PATH/test-*" 2>/dev/null || true
    echo "Cleanup Complete."
    sleep 1; clear; tput civis
}

# Initialize Selection
select_rules; select_target

# UI Configuration: cleanup on interrupt, term, or normal exit
cleanup() { tput cnorm 2>/dev/null; rm -f "${TMP_PREFIX}"_*; clear; exit 0; }
trap cleanup INT TERM
trap 'tput cnorm 2>/dev/null; rm -f "${TMP_PREFIX}"_*' EXIT
tput civis; clear

# Colors and Terminal Effects
GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); MAGENTA=$(tput setaf 5); CYAN=$(tput setaf 6)
RED_BOLD="$(tput setaf 1)$(tput bold)"
RED_BLINK="$(tput setaf 1)$(tput bold)$(tput blink)"
NC=$(tput sgr0)
# Use non-blink alert when PX_NO_BLINK=1
[[ "$PX_NO_BLINK" =~ ^[1yYtT] ]] && RED_BLINK="$RED_BOLD"
CLEAR_EOL=$(tput el)
MOVE_HOME=$(tput cup 0 0)
CLEAR_BELOW=$(tput ed)

# --- Main Monitoring Loop ---
while true; do
    COUNTER=$((COUNTER + 1))
    
    # Background: Fetch Cluster Status every 5 iterations
    if [ $((COUNTER % 5)) -eq 1 ]; then
        oc exec "$ANY_PX_POD" -n "$PX_NS" -- pxctl status > "${TMP_PREFIX}_cluster" 2>/dev/null &
        # Refresh Inspect Data to track replica/pool changes
        INSPECT_DATA=$(oc exec "$ANY_PX_POD" -n "$PX_NS" -- pxctl volume inspect "$VOL_ID" 2>/dev/null)
        # Keep REPLICA_IPS in sync so [4] shows correct (REPLICA) markers after resize
        REPLICA_IPS=$(echo "$INSPECT_DATA" | sed -n '/Replica sets on nodes:/,$p' | grep "Node" | awk -F': ' '{print $2}' | xargs)
    fi

    # Fetch Filesystem usage from inside the Pod
    DISK_RAW=$(oc exec "$POD_NAME" -n "$CURRENT_NS" -- df -h "$TARGET_PATH" 2>/dev/null | grep -v "Filesystem" | tail -n 1)
    PVC_CAP=$(oc get pvc "$PVC_NAME" -n "$CURRENT_NS" -o jsonpath='{.status.capacity.storage}' 2>/dev/null)

    # In-place refresh: move to top and redraw (no full clear = less flicker, more pro)
    printf "%s" "$MOVE_HOME"

    echo "===================================================================================================="
    echo " STATUS: PX-ALERT-MONITOR | Project: ${CYAN}$CURRENT_NS${NC} | Time: $(date +%H:%M:%S)${CLEAR_EOL}"
    echo " Pod: $POD_NAME | Mount: ${YELLOW}$TARGET_PATH${NC} | Vol: $VOL_ID${CLEAR_EOL}"
    echo "===================================================================================================="

    # [1. STORAGE LAYER]
    echo "${GREEN}[1. STORAGE LAYER]${NC}${CLEAR_EOL}"
    printf "%-25s %-15s %-10s %-10s %-10s %-10s\n" "PVC_NAME" "MOUNT" "PVC_SIZE" "FS_SIZE" "FS_USED" "FS_USE%" | sed "s/$/${CLEAR_EOL}/"

    f_sz=$(echo "$DISK_RAW" | awk '{print $2}'); f_ud=$(echo "$DISK_RAW" | awk '{print $3}')
    f_pc_raw=$(echo "$DISK_RAW" | awk '{print $5}' | tr -d '%')

    # Alert Logic: Red Blink if usage > PX_FS_WARN_PCT%
    if [ -n "$f_pc_raw" ] && [ "$f_pc_raw" -gt "$PX_FS_WARN_PCT" ] 2>/dev/null; then
        f_pc_display="${RED_BLINK}${f_pc_raw}%${NC}"
    else
        f_pc_display="${f_pc_raw}%"
    fi

    printf "%-25s %-15s %-10s %-10s %-10s " "$PVC_NAME" "${TARGET_PATH:0:14}" "$PVC_CAP" "$f_sz" "$f_ud"
    echo -e "${f_pc_display}${CLEAR_EOL}"
    echo "----------------------------------------------------------------------------------------------------${CLEAR_EOL}"

    # [2. ARO – RULE EVENTS] (Autopilot Rule Object: state & transitions per selected rule/PVC)
    echo "${YELLOW}[2. ARO – RULE EVENTS]${NC}${CLEAR_EOL}"
    for RULE in "${SELECTED_RULES[@]}"; do
        d_rule=$(echo $RULE | xargs); st=$(oc get autopilotrule "$d_rule" -o jsonpath='{.status.state}' 2>/dev/null)
        echo " > RULE: ${CYAN}$d_rule${NC} | STATE: ${st:-Active}${CLEAR_EOL}"
        evs=$(oc describe autopilotrule "$d_rule" 2>/dev/null | sed -n '/Events:/,$p' | grep "transition from" | tail -n 2)
        if [ -z "$evs" ]; then echo "    No transition events${CLEAR_EOL}"
        else echo "$evs" | awk -v cl="$CLEAR_EOL" '{match($0, /transition from /); t=($3~/invalid|^</||$3=="") ? " - " : $3; printf "    [%-8s] %s%s\n", t, substr($0, RSTART+16), cl}'; fi
    done

    # [3. TARGET STORAGE POOLS] - Drill down into Replica Sets
    echo -e "\n${MAGENTA}[3. TARGET STORAGE POOLS (DRILL DOWN)]${NC}${CLEAR_EOL}"
    printf "%-15s %-40s %-40s\n" "NODE_IP" "POOL_UUID" "DRIVE_PATH" | sed "s/$/${CLEAR_EOL}/"
    
    # Logic: Parse the 'Replica sets on nodes' block from pxctl inspect
    echo "$INSPECT_DATA" | sed -n '/Replica sets on nodes:/,/Replication Status/p' | while read -r line; do
        if [[ $line == *"Node"* ]]; then
            r_node=$(echo "$line" | awk -F': ' '{print $2}' | xargs)
            read next_line; r_pool=$(echo "$next_line" | awk -F': ' '{print $2}' | xargs)
            read next_line; # FA-Name
            read next_line; # Drive ID
            read next_line; r_path=$(echo "$next_line" | awk -F': ' '{print $2}' | xargs)
            
            printf "%-15s %-40s %-40s\n" "$r_node" "$r_pool" "$r_path" | sed "s/$/${CLEAR_EOL}/"
        fi
    done

    # [4. PX CLUSTER SUMMARY]
    echo -e "\n${CYAN}[4. PX CLUSTER SUMMARY]${NC}${CLEAR_EOL}"
    printf "%-15s %-45s %-10s %-15s\n" "NODE_IP" "NODE_NAME" "STATUS" "STORAGE_STATUS" | sed "s/$/${CLEAR_EOL}/"
    if [ -s "${TMP_PREFIX}_cluster" ]; then
        grep -E "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "${TMP_PREFIX}_cluster" | grep -vE "attached|raid|POOL|Device" | while read -r line; do
            ni=$(echo "$line" | awk '{print $1}')
            # Skip header-like lines (e.g. "IP:" from pxctl output)
            [[ "$ni" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
            nm=$(echo "$line" | awk '{print $3}'); ir=""
            # Mark if this node is part of the current volume's replica set
            [[ "$REPLICA_IPS" =~ "$ni" ]] && ir=" (REPLICA)"
            st=$(echo "$line" | grep -oE "Online|Offline"); ss=$(echo "$line" | grep -oE "Up \(This node\)|Up" | sed 's/ (This node)//' | head -n 1)
            printf "%-15s %-45s %-10s %-15s${YELLOW}%s${NC}\n" "$ni" "$nm" "$st" "$ss" "$ir" | sed "s/$/${CLEAR_EOL}/"
        done
    fi

    # [5. LOAD GENERATOR]
    echo -e "\n${GREEN}[5. LOAD GENERATOR]${NC}${CLEAR_EOL}"
    if [ -f "${TMP_PREFIX}_dd_pid" ] && kill -0 $(cat "${TMP_PREFIX}_dd_pid") 2>/dev/null; then
        LOAD_PROG=$(tail -n 1 "${TMP_PREFIX}_load_log" 2>/dev/null | tr '\r' '\n' | tail -n 1 | sed 's/.*copied, //')
        echo " STATUS: ${YELLOW}RUNNING...${NC} | $LOAD_PROG${CLEAR_EOL}"
    else
        echo " STATUS: ${CYAN}IDLE${NC} | Waiting for command...${CLEAR_EOL}"
    fi

    echo ""
    echo "----------------------------------------------------------------------------------------------------"
    echo -n " [t] Targets | [r] Rules | [l] Gen Load | [c] Clear | [q] Quit"
    printf "%s" "$CLEAR_BELOW"

    # Input handling: 5s refresh (smoother, more pro than 2s)
    read -t 5 -n 1 key
    case $key in
        t) tput cnorm; select_target; clear; tput civis ;;
        r) tput cnorm; select_rules; clear; tput civis ;;
        l) gen_load ;;
        c) clear_data ;;
        q) break ;;
    esac
done

# Exit Cleanup (EXIT trap also removes TMP_PREFIX files)
tput cnorm; clear; rm -f "${TMP_PREFIX}"_*