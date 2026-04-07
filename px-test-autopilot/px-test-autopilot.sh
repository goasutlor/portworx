#!/bin/bash
# ==============================================================================
# PX-ALERT-MONITOR: Portworx Volume and Autopilot Tracking Tool
# VERSION: 1.0.06022026
# Purpose: Monitor Portworx PVCs, Replica health, and Autopilot transitions
# Optional env: PX_NS (default portworx-cwdc), PX_FS_WARN_PCT (default 50), PX_NO_BLINK=1 to disable blink
# Section [2] prefers AutopilotRuleObject named like spec.volumeName (per-PVC); falls back to AutopilotRule Events if missing.
# PX_ARO_JOURNEY_MAX: max transition lines from ARO status.items (default 30, 0 = unlimited).
PX_ARO_JOURNEY_MAX="${PX_ARO_JOURNEY_MAX:-30}"
# PX_ARO_JOURNEY_DISPLAY: fixed rows for [2] journey (last N shown; pad with blanks so redraw never leaves ghost lines). 0 = show all (may scroll / smear into [3]).
PX_ARO_JOURNEY_DISPLAY="${PX_ARO_JOURNEY_DISPLAY:-8}"
# ==============================================================================

# Remark: Detect current active namespace or fallback to default
CURRENT_NS=$(oc project -q 2>/dev/null)
PX_NS="${PX_NS:-portworx-cwdc}"  # Override with env if needed

# Optional: FS usage % to trigger alert (default 50); set PX_NO_BLINK=1 to disable blink
PX_FS_WARN_PCT="${PX_FS_WARN_PCT:-50}"
PX_NO_BLINK="${PX_NO_BLINK:-0}"

# Unique temp prefix to avoid collision when multiple instances run
TMP_PREFIX="/tmp/px_monitor_$$"

# --- Function: Find first running Portworx pod in a namespace ---
find_px_pod_in_ns() {
    local ns="$1"
    oc get pods -n "$ns" -l name=portworx --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# --- Function: Resolve Portworx namespace/pod robustly ---
resolve_px_context() {
    local candidates detected_ns

    # Try explicit/default PX_NS first
    ANY_PX_POD=$(find_px_pod_in_ns "$PX_NS")
    if [ -n "$ANY_PX_POD" ]; then
        return
    fi

    # Then common candidates
    candidates=("$CURRENT_NS" "portworx-cwdc" "portworx-cwdc-dev" "kube-system")
    for ns in "${candidates[@]}"; do
        [ -n "$ns" ] || continue
        ANY_PX_POD=$(find_px_pod_in_ns "$ns")
        if [ -n "$ANY_PX_POD" ]; then
            PX_NS="$ns"
            return
        fi
    done

    # Final fallback: discover from all namespaces
    detected_ns=$(oc get pods -A -l name=portworx \
      -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
    if [ -n "$detected_ns" ]; then
        ANY_PX_POD=$(find_px_pod_in_ns "$detected_ns")
        if [ -n "$ANY_PX_POD" ]; then
            PX_NS="$detected_ns"
            return
        fi
    fi

    echo "ERROR: Cannot find running Portworx pod (label: name=portworx) in any namespace."
    echo "Hint: export PX_NS=<your-portworx-namespace> and rerun."
    exit 1
}

# --- Function: Select AutopilotRules ---
select_rules() {
    clear
    echo "------------------------------------------------"
    echo " Step 1: Select AutopilotRules (legacy fallback if no AutopilotRuleObject for this volume)"
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

    # Identify any running Portworx pod to run pxctl commands
    resolve_px_context
    
    # Store Volume Inspection data for the loop
    INSPECT_DATA=$(oc exec "$ANY_PX_POD" -n "$PX_NS" -- pxctl volume inspect "$VOL_ID" 2>/dev/null)
    if [ -z "$INSPECT_DATA" ]; then
        INSPECT_DATA=$(oc exec "$ANY_PX_POD" -n "$PX_NS" -- /opt/pwx/bin/pxctl volume inspect "$VOL_ID" 2>/dev/null)
    fi
    
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

# Resolve Portworx context first (namespace + pod), then continue
resolve_px_context

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
        (
            oc exec "$ANY_PX_POD" -n "$PX_NS" -- pxctl status 2>/dev/null \
            || oc exec "$ANY_PX_POD" -n "$PX_NS" -- /opt/pwx/bin/pxctl status 2>/dev/null
        ) > "${TMP_PREFIX}_cluster" &
        # Refresh Inspect Data to track replica/pool changes
        INSPECT_DATA=$(oc exec "$ANY_PX_POD" -n "$PX_NS" -- pxctl volume inspect "$VOL_ID" 2>/dev/null)
        if [ -z "$INSPECT_DATA" ]; then
            INSPECT_DATA=$(oc exec "$ANY_PX_POD" -n "$PX_NS" -- /opt/pwx/bin/pxctl volume inspect "$VOL_ID" 2>/dev/null)
        fi
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

    # [2. ARO – per-PVC AutopilotRuleObject status.items, else AutopilotRule Events (shared)
    echo "${YELLOW}[2. ARO – RULE EVENTS]${NC}${CLEAR_EOL}"
    aro_name=$(oc get autopilotruleobject "$VOL_ID" -n "$CURRENT_NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
    if [ -n "$aro_name" ] && [ "$aro_name" = "$VOL_ID" ]; then
        aro_rule=$(oc get autopilotruleobject "$VOL_ID" -n "$CURRENT_NS" -o jsonpath='{.metadata.labels.rule}' 2>/dev/null)
        aro_desc=$(oc describe autopilotruleobjects "$VOL_ID" -n "$CURRENT_NS" 2>/dev/null)
        aro_st=$(echo "$aro_desc" | awk '/^[[:space:]]*State:[[:space:]]+/ {s=$2} END{print s}')
        echo "${CLEAR_EOL}"
        echo " > ARO:   ${CYAN}$VOL_ID${NC}${CLEAR_EOL}"
        echo "   RULE:  ${CYAN}${aro_rule:-?}${NC}${CLEAR_EOL}"
        echo "   STATE: ${CYAN}${aro_st:-?}${NC}${CLEAR_EOL}"
        echo "${CLEAR_EOL}"
        aro_lines=$(echo "$aro_desc" | awk '
            /^[[:space:]]*Status:/ {in_status=1; next}
            in_status && /^[[:space:]]*Events:/ {in_status=0}
            in_status && /^[[:space:]]*Last Process Timestamp:/ {
                ts=$0
                sub(/^[[:space:]]*Last Process Timestamp:[[:space:]]*/, "", ts)
                next
            }
            in_status && /^[[:space:]]*Message:/ {
                msg=$0
                sub(/^[[:space:]]*Message:[[:space:]]*/, "", msg)
                if (msg ~ /transition from/) {
                    print ts "\t" msg
                }
            }
        ' | sort)
        if [ -n "$PX_ARO_JOURNEY_MAX" ] && [ "$PX_ARO_JOURNEY_MAX" != "0" ]; then
            aro_lines=$(echo "$aro_lines" | tail -n "$PX_ARO_JOURNEY_MAX")
        fi
        # Fixed-height journey: always DISPLAY data rows (+ 2 header lines) so a shorter [2] redraw erases ghosts (no bleed into [3]).
        _tsw=23
        printf "    %-*s      %s${CLEAR_EOL}\n" "$_tsw" "WHEN (UTC)" "STATE TRANSITION"
        _dash=$(printf '%*s' "$_tsw" '' | tr ' ' '-')
        printf "    %-*s      %s${CLEAR_EOL}\n" "$_tsw" "$_dash" "------------------------------------------------------------------"
        _pad_line() { printf "    %-*s      %s${CLEAR_EOL}\n" "$_tsw" "" ""; }
        if [ -z "$aro_lines" ]; then
            printf "    %-*s      %s${CLEAR_EOL}\n" "$_tsw" "—" "(no transitions in status.items)"
            n_show=1
        elif [ -n "$PX_ARO_JOURNEY_DISPLAY" ] && [ "$PX_ARO_JOURNEY_DISPLAY" != "0" ]; then
            aro_show=$(echo "$aro_lines" | tail -n "$PX_ARO_JOURNEY_DISPLAY")
            n_show=0
            while IFS=$'\t' read -r ts msg; do
                [ -n "$msg" ] || continue
                short_ts=$(echo "$ts" | sed 's/T/ /;s/Z$//')
                [ -z "$short_ts" ] && short_ts="—"
                trans=$(echo "$msg" | sed 's/.*transition from //')
                printf "    %-*s      %s${CLEAR_EOL}\n" "$_tsw" "$short_ts" "$trans"
                n_show=$((n_show + 1))
            done <<< "$aro_show"
        else
            n_show=0
            while IFS=$'\t' read -r ts msg; do
                [ -n "$msg" ] || continue
                short_ts=$(echo "$ts" | sed 's/T/ /;s/Z$//')
                [ -z "$short_ts" ] && short_ts="—"
                trans=$(echo "$msg" | sed 's/.*transition from //')
                printf "    %-*s      %s${CLEAR_EOL}\n" "$_tsw" "$short_ts" "$trans"
                n_show=$((n_show + 1))
            done <<< "$aro_lines"
        fi
        if [ -n "$PX_ARO_JOURNEY_DISPLAY" ] && [ "$PX_ARO_JOURNEY_DISPLAY" != "0" ]; then
            while [ "$n_show" -lt "$PX_ARO_JOURNEY_DISPLAY" ]; do _pad_line; n_show=$((n_show + 1)); done
        fi
    elif [ ${#SELECTED_RULES[@]} -gt 0 ]; then
        for RULE in "${SELECTED_RULES[@]}"; do
            d_rule=$(echo $RULE | xargs); st=$(oc get autopilotrule "$d_rule" -o jsonpath='{.status.state}' 2>/dev/null)
            echo "${CLEAR_EOL}"
            echo " > RULE:  ${CYAN}$d_rule${NC}${CLEAR_EOL}"
            echo "   STATE: ${CYAN}${st:-Active}${NC}${CLEAR_EOL}"
            echo "${CLEAR_EOL}"
            evs=$(oc describe autopilotrule "$d_rule" 2>/dev/null | sed -n '/Events:/,$p' | grep "transition from" | tail -n 12)
            if [ -n "$PX_ARO_JOURNEY_DISPLAY" ] && [ "$PX_ARO_JOURNEY_DISPLAY" != "0" ] && [ -n "$evs" ]; then
                evs=$(echo "$evs" | tail -n "$PX_ARO_JOURNEY_DISPLAY")
            fi
            if [ -z "$evs" ]; then echo "    No transition events${CLEAR_EOL}"
            else
                _tsw=10
                printf "    %-*s      %s${CLEAR_EOL}\n" "$_tsw" "AGE" "STATE TRANSITION"
                _dash=$(printf '%*s' "$_tsw" '' | tr ' ' '-')
                printf "    %-*s      %s${CLEAR_EOL}\n" "$_tsw" "$_dash" "------------------------------------------------------------------"
                n_ev=0
                while IFS= read -r evline; do
                    [ -z "$evline" ] && continue
                    out=$(echo "$evline" | awk -v tw="${_tsw}" -v cl="$CLEAR_EOL" '{match($0, /transition from /); age=($3~/invalid|^</||$3=="") ? "—" : $3; printf "    %-*s      %s%s\n", tw, age, substr($0, RSTART+16), cl}')
                    printf "%s\n" "$out"
                    n_ev=$((n_ev + 1))
                done <<< "$evs"
                if [ -n "$PX_ARO_JOURNEY_DISPLAY" ] && [ "$PX_ARO_JOURNEY_DISPLAY" != "0" ]; then
                    while [ "$n_ev" -lt "$PX_ARO_JOURNEY_DISPLAY" ]; do
                        printf "    %-*s      %s${CLEAR_EOL}\n" "$_tsw" "" ""
                        n_ev=$((n_ev + 1))
                    done
                fi
            fi
        done
    else
        echo "    No AutopilotRuleObject ${CYAN}$VOL_ID${NC} in ns ${CYAN}$CURRENT_NS${NC} and no rules selected for fallback.${CLEAR_EOL}"
    fi

    # [3. TARGET STORAGE POOLS] - Drill down into Replica Sets
    echo -e "\n${MAGENTA}[3. TARGET STORAGE POOLS (DRILL DOWN)]${NC}${CLEAR_EOL}"
    printf "%-6s %-15s %-40s %-40s\n" "SET" "NODE_IP" "POOL_UUID" "DRIVE_PATH" | sed "s/$/${CLEAR_EOL}/"

    # Parse "Replica sets on nodes" block in a format-tolerant way.
    # Some pxctl versions (e.g. local disk setups) do not include Drive Path lines.
    section3_rows_data=$(echo "$INSPECT_DATA" | awk '
        /Replica sets on nodes:/ {in_block=1; next}
        /Replication Status/ {in_block=0}
        in_block && /Set[[:space:]]+[0-9]+/ {
            set_id=$0
            sub(/^.*Set[[:space:]]+/, "", set_id)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", set_id)
        }
        in_block && /Node[[:space:]]*:/ {
            node=$0
            sub(/^.*:[[:space:]]*/, "", node)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", node)
        }
        in_block && /Pool UUID[[:space:]]*:/ {
            pool=$0
            sub(/^.*:[[:space:]]*/, "", pool)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", pool)
            if (node != "") printf "%-6s %-15s %-40s %-40s\n", (set_id==""?"-":set_id), node, pool, "N/A"
        }
    ')
    section3_rows=0
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        section3_rows=$((section3_rows + 1))
        echo "${row}${CLEAR_EOL}"
    done <<< "$section3_rows_data"
    if [ "$section3_rows" -eq 0 ]; then
        echo "No replica/pool rows parsed from pxctl inspect output.${CLEAR_EOL}"
    fi
    vol_ha=$(echo "$INSPECT_DATA" | awk -F':' '/^[[:space:]]*HA[[:space:]]*:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
    [ -n "$vol_ha" ] && echo " Note: This section shows volume replicas only (HA=${vol_ha}), not all cluster nodes.${CLEAR_EOL}"

    # [4. PX CLUSTER SUMMARY]
    echo -e "\n${CYAN}[4. PX CLUSTER SUMMARY]${NC}${CLEAR_EOL}"
    printf "%-15s %-45s %-10s %-15s\n" "NODE_IP" "NODE_NAME" "STATUS" "STORAGE_STATUS" | sed "s/$/${CLEAR_EOL}/"
    if [ -s "${TMP_PREFIX}_cluster" ]; then
        while IFS= read -r line; do
            ni=$(echo "$line" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -n 1)
            [ -n "$ni" ] || continue

            st=$(echo "$line" | grep -oE "Online|Offline|Degraded" | head -n 1)
            [ -n "$st" ] || continue

            ss=$(echo "$line" | grep -oE "Up \(This node\)|Up|Down" | head -n 1 | sed "s/ (This node)//")

            # SchedulerNodeName is consistently the 3rd column in "Cluster Summary" rows
            nm=$(echo "$line" | awk '{print $3}')
            [ -n "$nm" ] || nm="-"

            ir=""
            [[ "$REPLICA_IPS" =~ "$ni" ]] && ir=" (REPLICA)"

            printf "%-15s %-45s %-10s %-15s${YELLOW}%s${NC}\n" "$ni" "$nm" "$st" "${ss:-N/A}" "$ir" | sed "s/$/${CLEAR_EOL}/"
        done < "${TMP_PREFIX}_cluster"
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