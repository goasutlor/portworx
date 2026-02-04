#!/usr/bin/env bash
# ==============================================================================
# SCRIPT: px-health-check.sh
# AUTHOR: Sontas Jiamsripong
# LOGIC: Strict Ready-Check + Volume & PVC Inventory + Smart Debugging
# USE:   Run daily for ops healthcheck (e.g. cron: 0 8 * * * /path/px-health-check.sh)
# EXIT:  0 = cluster healthy, 1 = degraded (pods not ready), 2 = discovery failed
# LOG:   Set LOG_DIR (e.g. ./logs) to append report to logs/px-health-check_YYYYMMDD.log
# ENV:   POOL_UTIL_WARN=80 (warn when any pool >= this %; default 80)
# ==============================================================================

set -o pipefail
export TZ="Asia/Bangkok"
C_RES=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'; C_CYN=$'\033[1;36m'; C_MAG=$'\033[1;35m'

# Optional: write report to log file (set LOG_DIR or leave empty for stdout only)
LOG_DIR="${LOG_DIR:-./logs}"
LOG_FILE=""
[[ -n "$LOG_DIR" ]] && { mkdir -p "$LOG_DIR"; LOG_FILE="$LOG_DIR/px-health-check_$(date '+%Y%m%d').log"; }

report() { echo -e "$@"; [[ -n "$LOG_FILE" ]] && echo -e "$@" >> "$LOG_FILE"; }

# --- 1. DISCOVERY (robust: STC first, then fallback namespaces) ---
PX_NS=$(oc get stc -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
if [[ -z "$PX_NS" ]]; then
  for ns in portworx-tls2 portworx-cwdc portworx kube-system; do
    pod=$(oc get pods -n "$ns" -l name=portworx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -n "$pod" ]] && { PX_NS="$ns"; break; }
  done
fi
if [[ -z "$PX_NS" ]]; then
  found=$(oc get pods -A -l name=portworx -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
  [[ -n "$found" ]] && PX_NS="$found"
fi

MAIN_POD=$(oc -n "$PX_NS" get pods -l name=portworx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | head -n 1)

if [[ -z "$PX_NS" || -z "$MAIN_POD" ]]; then
  echo -e "${C_RED}ERROR: Portworx namespace or pod not found. Check 'oc get pods -A -l name=portworx'.${C_RES}" >&2
  exit 2
fi

STATUS_RAW=$(oc -n "$PX_NS" exec "$MAIN_POD" -- pxctl status 2>/dev/null)
ALERTS_RAW=$(oc -n "$PX_NS" exec "$MAIN_POD" -- pxctl alerts show 2>/dev/null)
POD_DATA=$(oc get pods -n "$PX_NS" --no-headers 2>/dev/null)

if [[ -z "$STATUS_RAW" ]]; then
  echo -e "${C_RED}ERROR: Could not get 'pxctl status' from $PX_NS/$MAIN_POD.${C_RES}" >&2
  exit 2
fi

START_TIME=$(date +%s)

# --- 2. OUTPUT (and optional log) ---
clear
report ""
report "${C_CYN}${C_BOLD}PORTWORX ENTERPRISE OPERATIONAL DASHBOARD v51.0${C_RES}"
report "Report Generated: $(date '+%Y-%m-%d %H:%M:%S') (BKK GMT+7)"
report "Namespace: ${PX_NS} | Pod: ${MAIN_POD}"
report "===================================================================================="

# --- I. CLUSTER & ENTITLEMENTS ---
report "${C_BOLD}${C_YEL}I. CLUSTER & ENTITLEMENTS${C_RES}"
CLUSTER_STATUS=$(echo "$STATUS_RAW" | grep -oE "Cluster Status: [A-Za-z]+" | head -n 1)
[[ -n "$CLUSTER_STATUS" ]] && report "  $CLUSTER_STATUS"
PX_VER=$(echo "$STATUS_RAW" | grep -oE "Version: [0-9.]+" | head -1)
[[ -n "$PX_VER" ]] && report "  $PX_VER"
NODE_COUNT=$(echo "$STATUS_RAW" | sed -n '/IP.*ID.*SchedulerNodeName/,/Global Storage Pool/p' | grep -cE '^[[:space:]]*[0-9]+\.' || true)
report "  Storage nodes            : ${NODE_COUNT:-0}"
CID=$(echo "$STATUS_RAW" | grep "Cluster ID" | awk '{print $3}')
DAYS_VAL=$(echo "$STATUS_RAW" | grep -oE "expires in [0-9]+" | awk '{print $3}')
EXP_DATE=$(date -d "+${DAYS_VAL:-0} days" "+%Y-%m-%d" 2>/dev/null || echo "N/A")
report "  Cluster Identifier       : $CID"
report "  Expiry Date              : ${C_RED}${EXP_DATE}${C_RES} (${C_YEL}In ${DAYS_VAL:-?} days${C_RES})"
# Licence warning for Ops
if [[ -n "$DAYS_VAL" && "$DAYS_VAL" =~ ^[0-9]+$ && "$DAYS_VAL" -lt 30 ]]; then
  report "  ${C_YEL}⚠ WARNING: Licence expires in ${DAYS_VAL} days. Plan renewal.${C_RES}"
fi
report "------------------------------------------------------------------------------------"

# --- II. STORAGE POOL UTILIZATION (with real UTIL%) ---
report "${C_BOLD}${C_YEL}II. STORAGE POOL UTILIZATION${C_RES}"
report "$(printf "${C_BOLD}%-15s | %12s | %12s | %8s | %s${C_RES}\n" "DATA IP" "CAPACITY" "USED" "UTIL%" "STATUS")"
report "------------------------------------------------------------------------------------"

POOL_UTIL_FILE=$(mktemp 2>/dev/null || echo "/tmp/px_util_$$")
: > "$POOL_UTIL_FILE"
echo "$STATUS_RAW" | sed -n '/IP.*ID.*SchedulerNodeName/,/Global Storage Pool/p' | grep -E '^[[:space:]]*[0-9]+\.' | while read -r line; do
  IP=$(echo "$line" | awk '{print $1}')
  CAP=$(echo "$line" | awk '{for(i=NF;i>0;i--) if($i=="TiB" || $i=="GiB") {print $(i-1) " " $i; break}}')
  USED=$(echo "$line" | awk '{f=0; for(i=NF;i>0;i--) if($i=="TiB" || $i=="GiB") {f++; if(f==2) {print $(i-1) " " $i; break}}}')
  STAT=$(echo "$line" | grep -oE "Online|Offline")
  CAP_GB=$(echo "$CAP" | awk '{n=$1; u=$2; if(u=="TiB") n=n*1024; print n+0}')
  USED_GB=$(echo "$USED" | awk '{n=$1; u=$2; if(u=="TiB") n=n*1024; print n+0}')
  UTIL="0.0"
  if [[ -n "$CAP_GB" && -n "$USED_GB" && "${CAP_GB:-0}" -gt 0 ]]; then
    UTIL=$(awk -v u="$USED_GB" -v c="$CAP_GB" 'BEGIN{printf "%.1f", (u/c)*100}')
  fi
  COLR="$C_GRN"
  [[ "$STAT" != "Online" ]] && COLR="$C_RED"
  report "$(printf "%-15s | %12s | %12s | %7s%% | ${COLR}%s${C_RES}" "$IP" "$CAP" "$USED" "$UTIL" "${STAT:-N/A}")"
  echo "$UTIL" >> "$POOL_UTIL_FILE"
done
# High utilization warning (threshold: 80%, override with POOL_UTIL_WARN)
POOL_UTIL_WARN="${POOL_UTIL_WARN:-80}"
if [[ -s "$POOL_UTIL_FILE" ]]; then
  MAX_UTIL=$(sort -n "$POOL_UTIL_FILE" | tail -1)
  if [[ -n "$MAX_UTIL" ]]; then
    MAX_UTIL_INT=${MAX_UTIL%%.*}
    [[ "$MAX_UTIL_INT" -ge "$POOL_UTIL_WARN" ]] && report "  ${C_YEL}⚠ WARNING: At least one pool at ${MAX_UTIL}% utilization (threshold: ${POOL_UTIL_WARN}%).${C_RES}"
  fi
fi
rm -f "$POOL_UTIL_FILE"
report "------------------------------------------------------------------------------------"

# --- III. VOLUME & PVC INVENTORY ---
report "${C_BOLD}${C_YEL}III. VOLUME & PVC INVENTORY${C_RES}"
ALL_PVC=$(oc get pvc -A --no-headers 2>/dev/null | wc -l)
ALL_PV=$(oc get pv --no-headers 2>/dev/null | wc -l)
PV_REL=$(oc get pv --no-headers 2>/dev/null | grep -c "Released" || true)
VOL_DET=$(oc -n "$PX_NS" exec "$MAIN_POD" -- pxctl volume list 2>/dev/null | grep -c "detached" || true)

report "  $(printf '%-40s : %s' 'Total PVCs (All Namespaces)' "$ALL_PVC")"
report "  $(printf '%-40s : %s' 'Total PVs (Cluster Wide)' "$ALL_PV")"
report "  $(printf '%-40s : %s' 'Total Released PVs (Orphaned)' "${PV_REL:-0}")"
report "  $(printf '%-40s : %s' 'Total Detached Volumes (Portworx)' "${VOL_DET:-0}")"
if [[ -n "$PV_REL" && "$PV_REL" -gt 0 ]]; then
  report "  ${C_YEL}⚠ WARNING: $PV_REL Released (orphaned) PV(s). Consider cleanup or reclaim.${C_RES}"
fi
report "------------------------------------------------------------------------------------"

# --- IV. ALERTS (BKK TIME) ---
report "${C_BOLD}${C_YEL}IV. CRITICAL SYSTEM ALERTS (LOCAL GMT+7)${C_RES}"
report "$(printf "${C_BOLD}%-15s | %-22s | %s${C_RES}\n" "TIME (BKK)" "ALERT TYPE" "INSIGHT")"
ALERT_LINES=$(echo "$ALERTS_RAW" | grep -Ei "ALARM|CRITICAL" | tail -n 10)
if [[ -z "$ALERT_LINES" ]]; then
  report "  ${C_GRN}No critical alarms in recent output.${C_RES}"
else
  echo "$ALERT_LINES" | while read -r line; do
    UTC_RAW=$(echo "$line" | grep -oE "[A-Z][a-z]{2} [0-9]+ [0-9:]{8} UTC [0-9]{4}" | head -n 1)
    BKK_TIME=$(date -d "$UTC_RAW" "+%m/%d %H:%M" 2>/dev/null || echo "--/-- --:--")
    TYPE=$(echo "$line" | awk '{print $2}')
    INSIGHT=$(echo "$line" | awk '{$1=$2=$3=$4=$5=$6=$7=$8=""; print $0}' | sed 's/^[[:space:]]*//; s/[0-9]\{15,\}//g')
    report "$(printf "%-15s | %-22s | %.70s" "${C_YEL}${BKK_TIME}${C_RES}" "$TYPE" "$INSIGHT")"
  done
fi
report "------------------------------------------------------------------------------------"

# --- V. POD ORCHESTRATION INVENTORY (READY-ONLY CHECK) ---
report "${C_BOLD}${C_YEL}V. POD ORCHESTRATION INVENTORY (READY CHECK)${C_RES}"
report "$(printf "${C_BOLD}%-55s | %-10s | %s${C_RES}\n" "POD NAME" "READY" "HEALTH STATUS")"
report "------------------------------------------------------------------------------------"

FAULTY_PODS=()
TOTAL_COUNT=0
HEALTHY_COUNT=0

while read -r line; do
  [[ -z "$line" ]] && continue
  ((TOTAL_COUNT++))
  NAME=$(echo "$line" | awk '{print $1}')
  READY=$(echo "$line" | awk '{print $2}')
  STAT=$(echo "$line" | awk '{print $3}')

  R_NOW=$(echo "$READY" | cut -d'/' -f1)
  R_REQ=$(echo "$READY" | cut -d'/' -f2)

  if [[ "$R_NOW" != "$R_REQ" ]]; then
    STATUS_TAG="${C_RED}✘ NOT READY${C_RES}"
    FAULTY_PODS+=("$NAME")
  elif [[ "$STAT" != "Running" ]]; then
    STATUS_TAG="${C_RED}✘ $STAT${C_RES}"
    FAULTY_PODS+=("$NAME")
  else
    STATUS_TAG="${C_GRN}✔ HEALTHY${C_RES}"
    ((HEALTHY_COUNT++))
  fi
  report "$(printf "%-55s | %-10s | %s" "${NAME:0:54}" "$READY" "$STATUS_TAG")"
done <<< "$POD_DATA"

report "------------------------------------------------------------------------------------"
report "${C_BOLD}FINAL CONCLUSION:${C_RES}"
EXIT_CODE=0
if [[ "$HEALTHY_COUNT" -eq "$TOTAL_COUNT" && "$TOTAL_COUNT" -gt 0 ]]; then
  report "  ${C_GRN}✔ CLUSTER HEALTHY:${C_RES} All pods fully ready ($HEALTHY_COUNT/$TOTAL_COUNT)."
else
  EXIT_CODE=1
  report "  ${C_RED}✘ CLUSTER DEGRADED:${C_RES} $((${#FAULTY_PODS[@]})) pod(s) are NOT READY."
  report ""
  report "${C_BOLD}${C_YEL}>>> ACTIONS REQUIRED / DEBUG COMMANDS:${C_RES}"
  for pod in "${FAULTY_PODS[@]}"; do
    report "  ${C_CYN}# Analyze $pod:${C_RES}"
    report "  oc describe pod $pod -n $PX_NS"
    report "  oc logs $pod -n $PX_NS --all-containers --tail=50"
  done
fi

RUNTIME=$(($(date +%s) - START_TIME))
report "------------------------------------------------------------------------------------"
report "Runtime: ${RUNTIME}s"
# One-line summary for cron/monitoring (grep PX_HEALTH_CHECK_RESULT)
RESULT_LABEL="OK"
[[ $EXIT_CODE -eq 1 ]] && RESULT_LABEL="DEGRADED"
[[ $EXIT_CODE -eq 2 ]] && RESULT_LABEL="FAIL"
report "PX_HEALTH_CHECK_RESULT=${RESULT_LABEL} exit_code=${EXIT_CODE} runtime_sec=${RUNTIME}"
if [[ -n "$LOG_FILE" ]]; then
  report "Log written to: ${LOG_FILE}"
fi
report "===================================================================================="
exit "$EXIT_CODE"
