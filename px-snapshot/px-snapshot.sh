#!/bin/bash
# --- PORTWORX COMMANDER - STS-safe Restore (STORK + CSI Manual) [CLUSTER SCAN + GROUP BY NS] ---
# VERSION: 1.0.06022026
# AUTHOR: Sontas Jiamsripong
set -o pipefail
export TZ="Asia/Bangkok"

S_CLASS="${S_CLASS:-px-csi-snapclass}"
LOG_DIR="./logs"; mkdir -p "$LOG_DIR"

# Filter ONLY Portworx PVCs by StorageClassName regex (override if needed)
PX_SC_REGEX="${PX_SC_REGEX:-.*(px|portworx).*}"

# Colors & Style
G='\033[0;32m'; Y='\033[1;33m'; M='\033[0;35m'; C='\033[0;36m'; R='\033[0;31m'; B='\033[1m'; NC='\033[0m'; EL='\e[K'
write_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_DIR/px_commander_$(date +%Y%m%d).log"; }

# --- 1) Dynamic Engine Discovery (same as master) ---
discover_px() {
  echo -ne "${Y}Discovering Portworx Engine...${NC}"
  for ns in "portworx-tls2" "portworx-cwdc" "portworx" "kube-system"; do
    local pod
    pod=$(oc get pods -n "$ns" -l name=portworx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$pod" ]]; then
      PX_NAMESPACE="$ns"; PX_POD="$pod"
      echo -e " [${G}FOUND: $ns${NC}]"; return 0
    fi
  done

  local found
  found=$(oc get pods -A -l name=portworx -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
  if [[ -n "$found" ]]; then
    PX_NAMESPACE="$found"
    PX_POD=$(oc get pods -n "$found" -l name=portworx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    echo -e " [${G}FOUND: $found${NC}]"
  else
    echo -e " [${R}NOT FOUND${NC}]"
    echo -ne "${Y}Enter Portworx Namespace manually: ${NC}"; read -r PX_NAMESPACE
    PX_POD=$(oc get pods -n "$PX_NAMESPACE" -l name=portworx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  fi
}
discover_px

# --- Global inventory arrays ---
declare -a ALL_KEY        # "ns/pvc"
declare -a ALL_NS
declare -a ALL_PVC
declare -a SELECTED_STATUS

# Cached json blobs (cluster-wide)
all_pvc_json='{"items":[]}'
all_sched_json='{"items":[]}'        # VolumeSnapshotSchedule (STORK)
all_stork_vs_json='{"items":[]}'     # stork-volumesnapshot
all_csi_vs_json='{"items":[]}'       # volumesnapshot
all_px_snaps=""

# --- Helpers ---
pvc_base() { local pvc="$1"; echo "$pvc" | sed -E 's/-[0-9]+$//'; }

fmt_hms() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == "null" ]] && { echo "---"; return; }
  TZ="Asia/Bangkok" date -d "$ts" +"%m-%d %H:%M:%S" 2>/dev/null || echo "---"
}
to_epoch_utc() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == "null" ]] && { echo ""; return; }
  date -u -d "$ts" +%s 2>/dev/null || echo ""
}
fmt_hms_epoch() {
  local epoch="$1"
  [[ -z "$epoch" || "$epoch" == "null" ]] && { echo "---"; return; }
  TZ="Asia/Bangkok" date -d "@$epoch" +"%m-%d %H:%M:%S" 2>/dev/null || echo "---"
}

policy_to_seconds() {
  local pol="$1"
  [[ -z "$pol" || "$pol" == "---" || "$pol" == "MULTI" ]] && { echo ""; return; }
  pol="${pol#p-}"
  local token n unit
  token="$(echo "$pol" | grep -oE 'i[0-9]+[smhd]' | head -n 1 || true)"
  [[ -z "$token" ]] && { echo ""; return; }
  n="$(echo "$token" | grep -oE '[0-9]+' | head -n 1 || true)"
  unit="$(echo "$token" | grep -oE '[smhd]$' | head -n 1 || true)"
  [[ -z "$n" || -z "$unit" ]] && { echo ""; return; }
  case "$unit" in
    s) echo $((n)) ;;
    m) echo $((n*60)) ;;
    h) echo $((n*3600)) ;;
    d) echo $((n*86400)) ;;
    *) echo "" ;;
  esac
}

daily_policy_next_utc_iso() {
  # policy name format: dHHMMm-rN  (e.g., d1620m-r1) => daily at HH:MM (LOCAL/Bangkok)
  local pol="$1"
  [[ -z "$pol" || "$pol" == "---" || "$pol" == "MULTI" ]] && { echo ""; return; }
  pol="${pol#p-}"
  local hhmm
  hhmm="$(echo "$pol" | grep -oE '^d[0-9]{4}' | sed -E 's/^d//' || true)"
  [[ -z "$hhmm" ]] && { echo ""; return; }
  local hh="${hhmm:0:2}" mm="${hhmm:2:2}"
  [[ "$hh" =~ ^[0-9]{2}$ && "$mm" =~ ^[0-9]{2}$ ]] || { echo ""; return; }

  # compute next occurrence in Asia/Bangkok, then return UTC ISO Z
  local now_bkk today_target_epoch next_epoch
  now_bkk=$(TZ="Asia/Bangkok" date +%s)
  today_target_epoch=$(TZ="Asia/Bangkok" date -d "$(TZ="Asia/Bangkok" date +%F) ${hh}:${mm}:00" +%s 2>/dev/null || echo "")
  [[ -z "$today_target_epoch" ]] && { echo ""; return; }

  if (( now_bkk < today_target_epoch )); then
    next_epoch="$today_target_epoch"
  else
    next_epoch=$(TZ="Asia/Bangkok" date -d "tomorrow ${hh}:${mm}:00" +%s 2>/dev/null || echo "")
  fi
  [[ -z "$next_epoch" ]] && { echo ""; return; }
  date -u -d "@$next_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo ""
}


# ---- Quantity helpers for CSI restore size fix ----
qty_to_bytes() {
  local q="$1"
  [[ -z "$q" ]] && { echo 0; return; }
  q="${q// /}"
  local num unit
  num="$(echo "$q" | sed -E 's/([0-9.]+).*/\1/')"
  unit="$(echo "$q" | sed -E 's/[0-9.]+//')"

  awk -v n="$num" -v u="$unit" 'BEGIN{
    mult=1
    if(u=="Ki") mult=1024
    else if(u=="Mi") mult=1024^2
    else if(u=="Gi") mult=1024^3
    else if(u=="Ti") mult=1024^4
    else if(u=="Pi") mult=1024^5
    else if(u=="Ei") mult=1024^6
    else if(u=="K") mult=1000
    else if(u=="M") mult=1000^2
    else if(u=="G") mult=1000^3
    else if(u=="T") mult=1000^4
    else if(u=="P") mult=1000^5
    else if(u=="E") mult=1000^6
    else mult=1
    printf("%.0f\n", n*mult)
  }'
}
max_qty() {
  local a="$1" b="$2"
  [[ -z "$a" ]] && { echo "$b"; return; }
  [[ -z "$b" ]] && { echo "$a"; return; }
  local ab bb
  ab=$(qty_to_bytes "$a"); bb=$(qty_to_bytes "$b")
  if [[ "$ab" -ge "$bb" ]]; then echo "$a"; else echo "$b"; fi
}

# --- Global refresh (fast: one call per resource) ---
refresh_data() {
  # PVCs (all namespaces), keep only Portworx by storageClassName regex
  all_pvc_json="$(oc get pvc -A -o json 2>/dev/null || echo '{"items":[]}')"

  # Build key list in stable sorted order: namespace then pvc
  mapfile -t ALL_KEY < <(
    echo "$all_pvc_json" | jq -r --arg re "$PX_SC_REGEX" '
      .items[]
      | select((.spec.storageClassName // "") | test($re; "i"))
      | "\(.metadata.namespace)/\(.metadata.name)"
    ' 2>/dev/null | sort
  )

  ALL_NS=(); ALL_PVC=()
  for k in "${ALL_KEY[@]}"; do
    ALL_NS+=("${k%%/*}")
    ALL_PVC+=("${k#*/}")
  done

  # keep selection array length matched
  if [[ ${#SELECTED_STATUS[@]} -ne ${#ALL_KEY[@]} ]]; then
    SELECTED_STATUS=()
    for ((i=0;i<${#ALL_KEY[@]};i++)); do SELECTED_STATUS[$i]=0; done
  fi

  # STORK schedules/snapshots and CSI snapshots cluster-wide
  all_sched_json="$(oc get volumesnapshotschedule -A -o json 2>/dev/null || echo '{"items":[]}')"
  all_stork_vs_json="$(oc get stork-volumesnapshot -A -o json 2>/dev/null || echo '{"items":[]}')"
  all_csi_vs_json="$(oc get volumesnapshot -A -o json 2>/dev/null || echo '{"items":[]}')"

  # Portworx snapshot inventory (best-effort)
  all_px_snaps=$(oc exec -n "$PX_NAMESPACE" "$PX_POD" -- /opt/pwx/bin/pxctl volume list --snapshot 2>/dev/null || true)
}

# --- Query helpers (cluster-wide caches) ---
get_schedules_for_pvc() {
  local ns="$1" pvc="$2" base
  base="$(pvc_base "$pvc")"
  echo "$all_sched_json" | jq -r --arg ns "$ns" --arg pvc "$pvc" --arg base "$base" '
    .items[]
    | select(.metadata.namespace==$ns)
    | select(
        (.spec.template.spec.persistentVolumeClaimName==$pvc)
        or (.spec.template.spec.persistentVolumeClaimName==$base)
        or (.metadata.labels["portworx-pvc"]==$pvc)
        or (.metadata.labels["portworx-pvc"]==$base)
        or (.metadata.name==("sched-"+$pvc))
        or (.metadata.name==("sched-"+$base))
      )
    | .metadata.name
  ' 2>/dev/null | awk 'NF'
}

get_sched_for_pvc_one_json() {
  local ns="$1" pvc="$2"
  local sname
  sname="$(get_schedules_for_pvc "$ns" "$pvc" | head -n 1)"
  [[ -z "$sname" ]] && { echo ""; return; }
  echo "$all_sched_json" | jq -c --arg ns "$ns" --arg sname "$sname" '
    .items[] | select(.metadata.namespace==$ns and .metadata.name==$sname)
  ' 2>/dev/null | head -n 1
}

count_stork_snaps() {
  local ns="$1" pvc="$2" base
  base="$(pvc_base "$pvc")"
  echo "$all_stork_vs_json" | jq -r --arg ns "$ns" --arg pvc "$pvc" --arg base "$base" '
    [ .items[]
      | select(.metadata.namespace==$ns)
      | select(.spec.persistentVolumeClaimName==$pvc or .spec.persistentVolumeClaimName==$base)
    ] | length
  ' 2>/dev/null | awk '{print $1}'
}

count_csi_snaps() {
  local ns="$1" pvc="$2"
  echo "$all_csi_vs_json" | jq -r --arg ns "$ns" --arg pvc "$pvc" '
    [ .items[]
      | select(.metadata.namespace==$ns)
      | select(.spec.source.persistentVolumeClaimName==$pvc)
    ] | length
  ' 2>/dev/null | awk '{print $1}'
}

get_last_snap_time() {
  local ns="$1" pvc="$2" base
  base="$(pvc_base "$pvc")"

  local stork_last csi_last
  stork_last="$(echo "$all_stork_vs_json" | jq -r --arg ns "$ns" --arg pvc "$pvc" --arg base "$base" '
    [ .items[]
      | select(.metadata.namespace==$ns)
      | select(.spec.persistentVolumeClaimName==$pvc or .spec.persistentVolumeClaimName==$base)
      | (.metadata.creationTimestamp // empty)
    ] | sort | last // empty
  ' 2>/dev/null)"

  csi_last="$(echo "$all_csi_vs_json" | jq -r --arg ns "$ns" --arg pvc "$pvc" '
    [ .items[]
      | select(.metadata.namespace==$ns)
      | select(.spec.source.persistentVolumeClaimName==$pvc)
      | (.status.creationTime // .metadata.creationTimestamp // empty)
    ] | sort | last // empty
  ' 2>/dev/null)"

  if [[ -z "$stork_last" ]]; then echo "$csi_last"; return; fi
  if [[ -z "$csi_last" ]]; then echo "$stork_last"; return; fi
  [[ "$stork_last" > "$csi_last" ]] && echo "$stork_last" || echo "$csi_last"
}

get_next_snap_time() {
  local sched_json="$1"

  # CSI VolumeSnapshotSchedule (external snapshotter) may expose nextExecutionTime
  local next
  next=$(echo "$sched_json" | jq -r '.status.nextExecutionTime // empty' 2>/dev/null)
  [[ -n "$next" ]] && { echo "$next"; return; }

  # STORK VolumeSnapshotSchedule does not reliably expose "next".
  # For interval-based schedules, infer the cadence from the last two Interval entries.
  local t1 t2 last_finish e1 e2 delta
  t1=$(echo "$sched_json" | jq -r '.status.items.Interval[-2].finishTimestamp // .status.items.Interval[-2].creationTimestamp // empty' 2>/dev/null)
  t2=$(echo "$sched_json" | jq -r '.status.items.Interval[-1].finishTimestamp // .status.items.Interval[-1].creationTimestamp // empty' 2>/dev/null)
  last_finish="$t2"
  if [[ -n "$t1" && -n "$t2" ]]; then
    e1=$(date -u -d "$t1" +%s 2>/dev/null || echo "")
    e2=$(date -u -d "$t2" +%s 2>/dev/null || echo "")
    if [[ -n "$e1" && -n "$e2" && "$e2" -gt "$e1" ]]; then
      delta=$((e2 - e1))
      # sanity window: 30s .. 7d
      if (( delta >= 30 && delta <= 604800 )); then
        date -u -d "@$((e2 + delta))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null
        return
      fi
    fi
  fi

  # Fallback: if policy name encodes interval minutes like i5m, use it.
  local pol mins
  pol=$(echo "$sched_json" | jq -r '.spec.schedulePolicyName // empty' 2>/dev/null)
  last_finish=$(echo "$sched_json" | jq -r '.status.items.Interval[-1].finishTimestamp // empty' 2>/dev/null)
  if [[ -n "$pol" && -n "$last_finish" ]]; then
    mins=$(echo "$pol" | grep -oE 'i[0-9]+m' | grep -oE '[0-9]+' | head -n 1)
    if [[ -n "$mins" ]]; then
      date -u -d "$last_finish + $mins minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null
      return
    fi
  fi
  # Fallback: if policy name encodes daily time like d1620m-r1, compute next day/time (LOCAL) and convert to UTC
  pol=$(echo "$sched_json" | jq -r '.spec.schedulePolicyName // empty' 2>/dev/null)
  if [[ -n "$pol" ]]; then
    local dnext
    dnext="$(daily_policy_next_utc_iso "$pol")"
    [[ -n "$dnext" ]] && { echo "$dnext"; return; }
  fi

  echo ""
}

detect_workload() {
  local ns="$1" pvc="$2"
  local w_kind="sts"
  local w_name
  w_name=$(echo "$pvc" | sed 's/^data-//; s/-[0-9]\+$//')
  if ! oc -n "$ns" get sts "$w_name" &>/dev/null; then
    w_kind="deploy"
  fi
  echo "$w_kind:$w_name"
}

wait_pods_gone() {
  local ns="$1" label="$2"
  local tries=120
  while [[ $tries -gt 0 ]]; do
    local cnt
    cnt=$(oc get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | wc -l | awk '{print $1}')
    [[ "$cnt" -eq 0 ]] && return 0
    echo -ne "\r  Waiting for pods to terminate... " && sleep 1
    tries=$((tries-1))
  done
  echo ""
  return 1
}

# STS-safe: wait until no pods matching workload name (e.g. kafka-0, kafka-1)
# Returns 0 when pods gone; 1 on timeout (caller should warn and optionally ask to continue)
wait_workload_pods_gone() {
  local ns="$1" wn="$2"
  local tries=600
  while [[ $tries -gt 0 ]]; do
    local cnt
    cnt=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep -E "^${wn}-" | wc -l | awk '{print $1}')
    [[ "$cnt" -eq 0 ]] && return 0
    echo -ne "\r  Waiting for Pods to stop... ($tries s)${EL}"
    sleep 5
    tries=$((tries-5))
  done
  echo ""
  return 1
}

# After wait_workload_pods_gone timeout: warn and ask. If user aborts, scale back up and return 1.
# Usage: wait_workload_pods_gone "$ns" "$wn" || workload_wait_abort "$ns" "$tk" "$wn" "$reps" && return 1
workload_wait_abort() {
  local ns="$1" tk="$2" wn="$3" reps="$4"
  echo -e "\n${R}WARNING: Timeout waiting for pods to stop.${NC}"
  echo -ne "${Y}Abort and scale back up? (y=abort / n=continue anyway): ${NC}"; read -r -n 1 ans; echo ""
  if [[ "${ans,,}" == "y" ]]; then
    oc -n "$ns" scale "$tk" "$wn" --replicas="$reps" 2>/dev/null || true
    echo -e "${Y}Scaled back to $reps. Aborted.${NC}"
    return 0
  fi
  return 1
}

# --- Actions ---
set_schedule() {
  echo -ne "
${EL}${Y}>>> Type [ (i)nterval / (d)aily / (w)eekly / (m)onthly ]: ${NC}"; read -r -n 1 stype
  echo ""

  # Convert local (Asia/Bangkok) HH:MM -> UTC time.Kitchen (e.g. 05:30AM)
  local_to_utc_kitchen() {
    local hhmm="$1"
    local hh="${hhmm%%:*}" mm="${hhmm##*:}"
    [[ "$hh" =~ ^[0-9]+$ ]] || return 1
    [[ "$mm" =~ ^[0-9]+$ ]] || return 1
    (( hh=10#$hh, mm=10#$mm ))
    (( hh<0 || hh>23 || mm<0 || mm>59 )) && return 1

    local shift=-7  # Bangkok(+7) -> UTC
    local utc_h=$((hh + shift))
    local day_shift=0
    if (( utc_h < 0 )); then
      utc_h=$((utc_h + 24)); day_shift=-1
    elif (( utc_h >= 24 )); then
      utc_h=$((utc_h - 24)); day_shift=1
    fi

    local ampm="AM" h12=$utc_h
    if (( utc_h == 0 )); then h12=12; ampm="AM"
    elif (( utc_h < 12 )); then h12=$utc_h; ampm="AM"
    elif (( utc_h == 12 )); then h12=12; ampm="PM"
    else h12=$((utc_h-12)); ampm="PM"
    fi

    printf "%d:%02d%s|%d\n" "$h12" "$mm" "$ampm" "$day_shift"
  }

  # Map weekday for STORK (Sun/Mon/...)
  dow_norm() {
    case "${1,,}" in
      sun|sunday) echo "Sunday" ;;
      mon|monday) echo "Monday" ;;
      tue|tues|tuesday) echo "Tuesday" ;;
      wed|wednesday) echo "Wednesday" ;;
      thu|thur|thurs|thursday) echo "Thursday" ;;
      fri|friday) echo "Friday" ;;
      sat|saturday) echo "Saturday" ;;
      *) echo "" ;;
    esac
  }
  dow_shift() {
    # shift weekday by -1 or +1
    local d="$1" s="$2"
    local arr=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)
    local i
    for i in "${!arr[@]}"; do [[ "${arr[$i]}" == "$d" ]] && break; done
    [[ $i -ge 7 ]] && echo "" && return
    local ni=$(( (i + s) % 7 ))
    (( ni < 0 )) && ni=$((ni+7))
    echo "${arr[$ni]}"
  }

  local pol_spec="" pn="" iv="" rt="" tm="" day="" mdate=""
  local ktime day_shift ktime_only

  if [[ ${stype,,} == "i" ]]; then
    echo -ne "${Y}>>> Interval (Min): ${NC}"; read -r iv
    echo -ne "${Y}>>> Retain Count: ${NC}"; read -r rt
    [[ -z "$iv" || -z "$rt" ]] && return
    pn="p-i${iv}m-r${rt}"
    pol_spec="interval: { intervalMinutes: $iv, retain: $rt }"

  elif [[ ${stype,,} == "d" ]]; then
    echo -ne "${Y}>>> Time (HH:MM, Local): ${NC}"; read -r tm
    echo -ne "${Y}>>> Retain Count: ${NC}"; read -r rt
    [[ -z "$tm" || -z "$rt" ]] && return
    local conv; conv=$(local_to_utc_kitchen "$tm") || return
    ktime_only="${conv%%|*}"; day_shift="${conv##*|}"
    pn="p-d${tm/:/}m-r${rt}"
    pol_spec="daily: { time: \"${ktime_only}\", retain: $rt }"
    write_log "TIME" "Daily local ${tm} -> UTC ${ktime_only} (dayShift=${day_shift})"

  elif [[ ${stype,,} == "w" ]]; then
    echo -ne "${Y}>>> Day (Mon/Tue/Wed/Thu/Fri/Sat/Sun): ${NC}"; read -r day
    day=$(dow_norm "$day")
    [[ -z "$day" ]] && return
    echo -ne "${Y}>>> Time (HH:MM, Local): ${NC}"; read -r tm
    echo -ne "${Y}>>> Retain Count: ${NC}"; read -r rt
    [[ -z "$tm" || -z "$rt" ]] && return
    local conv; conv=$(local_to_utc_kitchen "$tm") || return
    ktime_only="${conv%%|*}"; day_shift="${conv##*|}"
    # If time shift crosses day boundary, shift weekday accordingly
    local uday="$day"
    if [[ "$day_shift" == "-1" ]]; then
      uday=$(dow_shift "$day" -1)
    elif [[ "$day_shift" == "1" ]]; then
      uday=$(dow_shift "$day" 1)
    fi
    pn="p-w${day:0:3}${tm/:/}m-r${rt}"
    pol_spec="weekly: { day: \"${uday}\", time: \"${ktime_only}\", retain: $rt }"
    write_log "TIME" "Weekly local ${day} ${tm} -> UTC ${uday} ${ktime_only} (dayShift=${day_shift})"

  elif [[ ${stype,,} == "m" ]]; then
    echo -ne "${Y}>>> Date (1-31): ${NC}"; read -r mdate
    echo -ne "${Y}>>> Time (HH:MM, Local): ${NC}"; read -r tm
    echo -ne "${Y}>>> Retain Count: ${NC}"; read -r rt
    [[ -z "$mdate" || -z "$tm" || -z "$rt" ]] && return
    [[ "$mdate" =~ ^[0-9]+$ ]] || return
    local conv; conv=$(local_to_utc_kitchen "$tm") || return
    ktime_only="${conv%%|*}"; day_shift="${conv##*|}"
    local udate="$mdate"
    # If time shift goes to previous UTC day, monthly date should decrement.
    if [[ "$day_shift" == "-1" ]]; then
      if [[ "$mdate" -gt 1 ]]; then
        udate=$((mdate-1))
      else
        # Can't safely roll to prev month without context; keep 1 and log.
        udate=1
      fi
    elif [[ "$day_shift" == "1" ]]; then
      udate=$((mdate+1))
      [[ "$udate" -gt 31 ]] && udate=31
    fi
    pn="p-m${mdate}${tm/:/}m-r${rt}"
    pol_spec="monthly: { date: $udate, time: \"${ktime_only}\", retain: $rt }"
    write_log "TIME" "Monthly local date ${mdate} ${tm} -> UTC date ${udate} ${ktime_only} (dayShift=${day_shift})"

  else
    return
  fi

  oc apply -f - <<EOF >/dev/null 2>&1
apiVersion: stork.libopenstorage.org/v1alpha1
kind: SchedulePolicy
metadata: { name: $pn }
policy: { $pol_spec }
EOF

  # protect: if any selected PVC has an existing schedule, ask replace/keep/cancel
  local any_existing=0
  for i in "${!ALL_KEY[@]}"; do
    [[ ${SELECTED_STATUS[$i]} -ne 1 ]] && continue
    local ns="${ALL_NS[$i]}" pvc="${ALL_PVC[$i]}"
    if [[ -n "$(get_schedules_for_pvc "$ns" "$pvc" | head -n 1)" ]]; then
      any_existing=1; break
    fi
  done

  local mode="replace"
  if [[ $any_existing -eq 1 ]]; then
    echo -e "
${R}${B}WARNING: Existing schedule(s) detected for selected PVC(s).${NC}"
    echo -e "${R}Creating new schedules without removing old ones may create trash and UI will show MULTI.${NC}"
    echo -e "${Y}Choose:${NC}"
    echo -e "  [${B}1${NC}] Replace (delete old schedule objects, keep snapshots)"
    echo -e "  [${B}2${NC}] Keep (create additional schedules)"
    echo -e "  [${B}3${NC}] Cancel"
    echo -ne "Select [1/2/3]: "; read -r ans
    case "$ans" in
      1) mode="replace" ;;
      2) mode="keep" ;;
      *) return ;;
    esac
  fi

  for i in "${!ALL_KEY[@]}"; do
    [[ ${SELECTED_STATUS[$i]} -ne 1 ]] && continue
    local ns="${ALL_NS[$i]}" pvc="${ALL_PVC[$i]}"

    if [[ "$mode" == "replace" ]]; then
      get_schedules_for_pvc "$ns" "$pvc" | while read -r sname; do
        [[ -n "$sname" ]] && oc -n "$ns" delete volumesnapshotschedule "$sname" --cascade=orphan --wait=false >/dev/null 2>&1 || true
      done
    fi

    local sname="sched-$pvc"
    [[ "$mode" == "keep" ]] && sname="sched-$pvc-${pn}-$(date +%H%M%S)"

    oc apply -f - <<EOF >/dev/null 2>&1
apiVersion: stork.libopenstorage.org/v1alpha1
kind: VolumeSnapshotSchedule
metadata:
  name: $sname
  namespace: $ns
  labels:
    portworx-pvc: "$pvc"
spec:
  schedulePolicyName: $pn
  template:
    spec:
      persistentVolumeClaimName: $pvc
      snapshotClassName: $S_CLASS
EOF
    write_log "SCHED" "Applied $pn to $ns/$pvc (mode=$mode name=$sname)"
  done

  SELECTED_STATUS=()
  refresh_data
}

unschedule_action() {
  echo -ne "\r${EL}${Y}>>> Stop Schedule for selected? (Snapshots are KEPT) (y/n): ${NC}"; read -r -n 1 confirm
  echo ""
  [[ ${confirm,,} != "y" ]] && return

  for i in "${!ALL_KEY[@]}"; do
    [[ ${SELECTED_STATUS[$i]} -ne 1 ]] && continue
    local ns="${ALL_NS[$i]}" pvc="${ALL_PVC[$i]}"
    get_schedules_for_pvc "$ns" "$pvc" | while read -r sname; do
      [[ -n "$sname" ]] && oc -n "$ns" delete volumesnapshotschedule "$sname" --cascade=orphan --wait=false >/dev/null 2>&1 || true
    done
    write_log "UNSCHED" "Stopped schedule(s) for $ns/$pvc"
  done

  SELECTED_STATUS=()
  refresh_data
}

manual_snap_csi() {
  local count=0
  for i in "${!ALL_KEY[@]}"; do
    [[ ${SELECTED_STATUS[$i]} -ne 1 ]] && continue
    local ns="${ALL_NS[$i]}" pvc="${ALL_PVC[$i]}"
    local sn="${pvc}-man-$(date +%s)"

    echo -e "${Y}>>> Creating CSI snapshot for $pvc in $ns...${NC}"
    if oc apply -f - <<EOF 2>/dev/null
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $sn
  namespace: $ns
  labels:
    portworx-pvc: "$pvc"
spec:
  snapshotClassName: $S_CLASS
  source:
    persistentVolumeClaimName: $pvc
EOF
    then echo -e "  [${G}OK${NC}] $sn"; count=$((count+1)); write_log "SNAP" "CSI manual snapshot created for $ns/$pvc -> $sn"
    else echo -e "  [${R}FAIL${NC}] $sn"; fi
  done
  [[ $count -eq 0 ]] && echo -e "${R}No selection. Use [t] to select PVC(s) first.${NC}"
  sleep 2; refresh_data
}

cleanup_action() {
  tput clear
  echo -e "${R}${B}=== CLEANUP (STORK + CSI) for selected PVC(s) ===${NC}"
  echo -e "${Y}This will delete schedules + snapshots for the selected PVC(s).${NC}"
  echo -e "${Y}You will lose recovery points for those PVC(s).${NC}\n"

  local selected_idx=()
  for i in "${!ALL_KEY[@]}"; do
    [[ ${SELECTED_STATUS[$i]} -ne 1 ]] && continue
    selected_idx+=("$i")
  done

  if [[ ${#selected_idx[@]} -eq 0 ]]; then
    echo -e "${R}No PVC selected.${NC}"
    read -p "Press Enter..."
    return
  fi

  echo -e "${C}${B}What will be deleted:${NC}"
  for i in "${selected_idx[@]}"; do
    local ns="${ALL_NS[$i]}" pvc="${ALL_PVC[$i]}" base
    base="$(pvc_base "$pvc")"

    local sch_n stork_n csi_n
    sch_n="$(get_schedules_for_pvc "$ns" "$pvc" | wc -l | awk '{print $1}')"
    stork_n="$(echo "$all_stork_vs_json" | jq -r --arg ns "$ns" --arg pvc "$pvc" --arg base "$base" '
      [ .items[]
        | select(.metadata.namespace==$ns)
        | select(.spec.persistentVolumeClaimName==$pvc or .spec.persistentVolumeClaimName==$base)
      ] | length
    ' 2>/dev/null)"
    csi_n="$(echo "$all_csi_vs_json" | jq -r --arg ns "$ns" --arg pvc "$pvc" '
      [ .items[]
        | select(.metadata.namespace==$ns)
        | select(.spec.source.persistentVolumeClaimName==$pvc)
      ] | length
    ' 2>/dev/null)"

    [[ -z "$stork_n" ]] && stork_n=0
    [[ -z "$csi_n" ]] && csi_n=0

    echo -e "  ${B}${ns}/${pvc}${NC}: schedules=${Y}$sch_n${NC}, storkSnaps=${Y}$stork_n${NC}, csiSnaps=${Y}$csi_n${NC}"
  done

  echo -e "\n${R}${B}WARNING:${NC} ${R}This cannot be undone.${NC}"
  echo -ne "${B}Type ${C}CLEAN${NC}${B} to proceed (or anything else to cancel): ${NC}"
  read -r confirm
  [[ "$confirm" != "CLEAN" ]] && { echo -e "${Y}Cancelled.${NC}"; read -p "Press Enter..."; return; }

  echo -e "\n${C}${B}Executing cleanup...${NC}"

  for i in "${selected_idx[@]}"; do
    local ns="${ALL_NS[$i]}" pvc="${ALL_PVC[$i]}" base
    base="$(pvc_base "$pvc")"

    # 1) delete schedules
    get_schedules_for_pvc "$ns" "$pvc" | while read -r sname; do
      [[ -n "$sname" ]] && oc -n "$ns" delete volumesnapshotschedule "$sname" --wait=false >/dev/null 2>&1 || true
    done

    # 2) delete stork snapshots
    echo "$all_stork_vs_json" | jq -r --arg ns "$ns" --arg pvc "$pvc" --arg base "$base" '
      .items[]
      | select(.metadata.namespace==$ns)
      | select(.spec.persistentVolumeClaimName==$pvc or .spec.persistentVolumeClaimName==$base)
      | .metadata.name
    ' 2>/dev/null | while read -r svs; do
      [[ -n "$svs" ]] && oc -n "$ns" delete stork-volumesnapshot "$svs" --wait=false >/dev/null 2>&1 || true
    done

    # 3) delete CSI snapshots
    echo "$all_csi_vs_json" | jq -r --arg ns "$ns" --arg pvc "$pvc" '
      .items[]
      | select(.metadata.namespace==$ns)
      | select(.spec.source.persistentVolumeClaimName==$pvc)
      | .metadata.name
    ' 2>/dev/null | while read -r vs; do
      [[ -n "$vs" ]] && oc -n "$ns" delete volumesnapshot "$vs" --wait=false >/dev/null 2>&1 || true
    done

    write_log "CLEANUP" "Cleanup executed: schedules+stork+CSI deleted for $ns/$pvc"
  done

  SELECTED_STATUS=()
  refresh_data
  echo -e "\n${G}${B}Cleanup completed.${NC}"
  read -p "Press Enter..."
}

# --- Restore: STORK + CSI (Manual), both use STS-safe scale/wait ---
restore_pvc() {
  refresh_data
  local sel_idx=()
  for i in "${!ALL_KEY[@]}"; do [[ "${SELECTED_STATUS[$i]}" -eq 1 ]] && sel_idx+=("$i"); done
  [[ ${#sel_idx[@]} -eq 0 ]] && return

  declare -a P_PVC P_SNAP P_NS
  declare -a C_CLONE_NS C_CLONE_PVC C_CLONE_VS
  declare -a R_NS R_PVC R_VS

  for idx in "${sel_idx[@]}"; do
    local t_ns="${ALL_NS[$idx]}" t_pvc="${ALL_PVC[$idx]}" t_base
    t_base="$(pvc_base "$t_pvc")"

    tput clear
    echo -e "${B}${M}>>> RESTORE: ${t_ns}/${t_pvc} — Choose source <<<${NC}\n"

    mapfile -t s_snaps < <(echo "$all_stork_vs_json" | jq -r --arg ns "$t_ns" --arg pvc "$t_pvc" --arg base "$t_base" '.items[] | select(.metadata.namespace==$ns) | select(.spec.persistentVolumeClaimName==$pvc or .spec.persistentVolumeClaimName==$base) | "\(.metadata.name)|\(.metadata.creationTimestamp // "")"' 2>/dev/null)
    mapfile -t c_snaps < <(echo "$all_csi_vs_json" | jq -r --arg ns "$t_ns" --arg pvc "$t_pvc" '.items[] | select(.metadata.namespace==$ns) | select(.spec.source.persistentVolumeClaimName==$pvc) | "\(.metadata.name)|\(.status.readyToUse // false)|\(.status.restoreSize // "")|\(.status.creationTime // .metadata.creationTimestamp // "")"' 2>/dev/null)

    local has_stork=0 has_csi=0
    [[ ${#s_snaps[@]} -gt 0 ]] && has_stork=1
    [[ ${#c_snaps[@]} -gt 0 ]] && has_csi=1

    if [[ $has_stork -eq 0 && $has_csi -eq 0 ]]; then
      echo -e "${R}No snapshots (STORK or CSI) for this PVC.${NC}"
      read -p "Press Enter..."
      continue
    fi

    echo -e "${C}Source:${NC}"
    [[ $has_stork -eq 1 ]] && echo -e "  [${B}S${NC}] STORK (Schedule) snapshots (${#s_snaps[@]})"
    [[ $has_csi -eq 1 ]] && echo -e "  [${B}C${NC}] CSI (Manual) VolumeSnapshots (${#c_snaps[@]})"
    echo -ne "  [${B}x${NC}] Skip this PVC\n\nChoice [S/C/x]: "; read -r src
    src="${src,,}"
    [[ -z "$src" || "$src" == "x" ]] && continue

    if [[ "$src" == "s" && $has_stork -eq 1 ]]; then
      local j=0
      for r in "${s_snaps[@]}"; do j=$((j+1)); printf " [%2d] %-55s | %s\n" "$j" "${r%%|*}" "$(fmt_hms "${r#*|}")"; done
      echo -ne "\nSelect ID: "; read -r ch
      if [[ "$ch" =~ ^[0-9]+$ && ch -ge 1 && ch -le j ]]; then
        P_PVC+=("$t_pvc"); P_SNAP+=("${s_snaps[$((ch-1))]%%|*}"); P_NS+=("$t_ns")
        write_log "RESTORE" "Queued STORK $t_ns/$t_pvc from ${s_snaps[$((ch-1))]%%|*}"
      fi
      continue
    fi

    if [[ "$src" == "c" && $has_csi -eq 1 ]]; then
      local j=0
      for row in "${c_snaps[@]}"; do
        j=$((j+1))
        local name ready size ts
        name="$(echo "$row" | cut -d'|' -f1)"; ready="$(echo "$row" | cut -d'|' -f2)"
        size="$(echo "$row" | cut -d'|' -f3)"; ts="$(echo "$row" | cut -d'|' -f4)"
        printf " [%2d] %-45s | ready=%-5s | %-10s | %s\n" "$j" "$name" "$ready" "${size:-}" "$(fmt_hms "$ts")"
      done
      echo -ne "\nSelect ID: "; read -r ch
      if [[ ! "$ch" =~ ^[0-9]+$ || ch -lt 1 || ch -gt j ]]; then
        echo -e "${Y}Invalid.${NC}"; sleep 1; continue
      fi
      local selected_vs
      selected_vs="$(echo "${c_snaps[$((ch-1))]}" | cut -d'|' -f1)"
      [[ -z "$selected_vs" ]] && continue

      echo -e "\n${Y}CSI restore:${NC}"
      echo -e "  [${B}1${NC}] Clone (new PVC, no scale)"
      echo -e "  [${B}2${NC}] Replace (in-place, STS-safe scale down/up)"
      echo -ne "Choose [1/2]: "; read -r mode
      [[ -z "$mode" ]] && continue

      if [[ "$mode" == "1" ]]; then
        C_CLONE_NS+=("$t_ns"); C_CLONE_PVC+=("$t_pvc"); C_CLONE_VS+=("$selected_vs")
        write_log "RESTORE" "Queued CSI clone $t_ns/$t_pvc from $selected_vs"
        continue
      fi

      if [[ "$mode" == "2" ]]; then
        local pv rp
        pv=$(oc -n "$t_ns" get pvc "$t_pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
        rp=$(oc get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || true)
        if [[ -n "$pv" && "$rp" != "Retain" ]]; then
          echo -e "${R}PV reclaimPolicy must be Retain for replace.${NC}"
          echo -e "${Y}oc patch pv $pv -p '{\"spec\":{\"persistentVolumeReclaimPolicy\":\"Retain\"}}'${NC}"
          read -p "Press Enter..."; continue
        fi
        R_NS+=("$t_ns"); R_PVC+=("$t_pvc"); R_VS+=("$selected_vs")
        write_log "RESTORE" "Queued CSI replace $t_ns/$t_pvc from $selected_vs"
      fi
    fi
  done

  # --- Execute CSI Clone (no scale) ---
  if [[ ${#C_CLONE_NS[@]} -gt 0 ]]; then
    echo -e "\n${C}${B}--- CSI Clone ---${NC}"
    for i in "${!C_CLONE_NS[@]}"; do
      local ns="${C_CLONE_NS[$i]}" pvc="${C_CLONE_PVC[$i]}" vs="${C_CLONE_VS[$i]}"
      local sc amodes req snap_req req_use newpvc
      sc=$(oc -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
      req=$(oc -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
      amodes=$(oc -n "$ns" get pvc "$pvc" -o json 2>/dev/null | jq -r '.spec.accessModes[]' 2>/dev/null | paste -sd, - || true)
      snap_req=$(oc -n "$ns" get volumesnapshot "$vs" -o jsonpath='{.status.restoreSize}' 2>/dev/null || true)
      req_use="$(max_qty "$req" "$snap_req")"; [[ -z "$req_use" ]] && req_use="${snap_req:-10Gi}"; [[ -z "$req_use" ]] && req_use="10Gi"
      [[ -z "$sc" || -z "$amodes" ]] && { echo -e "${R}Skip clone $ns/$pvc (no spec).${NC}"; continue; }
      newpvc="${pvc}-clone-$(date +%s)"
      if ! oc apply -f - <<EOF 2>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $newpvc, namespace: $ns }
spec:
  storageClassName: $sc
  accessModes: [${amodes//,/,\ }]
  resources: { requests: { storage: $req_use } }
  dataSource: { name: $vs, kind: VolumeSnapshot, apiGroup: snapshot.storage.k8s.io }
EOF
      then echo -e "${R}Failed to create clone PVC.${NC}"; continue; fi
      echo -ne "  $ns/$newpvc Bound... "
      for _ in {1..120}; do
        st=$(oc -n "$ns" get pvc "$newpvc" -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$st" == "Bound" ]] && { echo -e "${G}OK${NC}"; break; }; sleep 1
      done
      write_log "RESTORE" "CSI clone $ns/$newpvc from $vs"
    done
  fi

  # --- Execute STORK batch: group by (ns, workload), one scale/restore/scale per workload ---
  if [[ ${#P_PVC[@]} -gt 0 ]]; then
    echo -ne "\n${R}Proceed Scale Down & STORK Restore? (YES/no): ${NC}"; read -r final_ok
    [[ "$final_ok" != "YES" ]] && { SELECTED_STATUS=(); refresh_data; read -p "Done."; return; }

    local seen=""
    for i in "${!P_PVC[@]}"; do
      local ns="${P_NS[$i]}" wn tk reps
      wn=$(echo "${P_PVC[$i]}" | sed 's/^data-//; s/-[0-9]\+$//')
      tk="sts"; oc -n "$ns" get sts "$wn" &>/dev/null || tk="deploy"
      reps=$(oc -n "$ns" get "$tk" "$wn" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
      local key="${ns}:${wn}"
      [[ "$seen" == *"|${key}|"* ]] && continue
      seen="${seen}|${key}|"

      echo -e "\n${C}--- Workload $ns/$tk/$wn (replicas=$reps) ---${NC}"
      if ! oc -n "$ns" scale "$tk" "$wn" --replicas=0 2>/dev/null; then
        echo -e "${R}Scale down failed for $ns/$tk/$wn. Skipping this workload.${NC}"; continue
      fi
      if ! wait_workload_pods_gone "$ns" "$wn"; then
        workload_wait_abort "$ns" "$tk" "$wn" "$reps" && continue
      fi

      for j in "${!P_PVC[@]}"; do
        [[ "${P_NS[$j]}" != "$ns" ]] && continue
        local pwn=$(echo "${P_PVC[$j]}" | sed 's/^data-//; s/-[0-9]\+$//')
        [[ "$pwn" != "$wn" ]] && continue
        local res_obj="res-${P_PVC[$j]: -5}-$(date +%s)"
        if ! oc apply -f - <<EOF 2>/dev/null
apiVersion: stork.libopenstorage.org/v1alpha1
kind: VolumeSnapshotRestore
metadata: { name: $res_obj, namespace: ${P_NS[$j]} }
spec: { sourceName: ${P_SNAP[$j]}, sourceNamespace: ${P_NS[$j]} }
EOF
        then echo -e "${R}  Failed to create VolumeSnapshotRestore for ${P_PVC[$j]}${NC}"; continue; fi
        while true; do
          stat=$(oc -n "${P_NS[$j]}" get volumesnapshotrestore "$res_obj" -o jsonpath='{.status.status}' 2>/dev/null)
          msg=$(oc -n "${P_NS[$j]}" get events --field-selector involvedObject.name="$res_obj" --sort-by='.lastTimestamp' -o jsonpath='{.items[-1].message}' 2>/dev/null)
          echo -ne "\r  Restore: [${C}${stat:-Pending}${NC}] | ${Y}${msg:0:50}${NC}${EL}"
          [[ "$stat" == "Successful" || "$stat" == "Failed" ]] && break; sleep 4
        done; echo ""
      done

      if ! oc -n "$ns" scale "$tk" "$wn" --replicas="$reps" 2>/dev/null; then
        echo -e "${R}Scale up failed for $ns/$tk/$wn. Fix manually.${NC}"
      else
        sleep 3; oc -n "$ns" patch "$tk" "$wn" --type='merge' -p "{\"spec\":{\"replicas\":$reps}}" 2>/dev/null
      fi
    done
    echo -e "${G}>>> STORK Restore done.${NC}"
  fi

  # --- Execute CSI Replace (STS-safe: scale per workload) ---
  if [[ ${#R_PVC[@]} -gt 0 ]]; then
    local i ns wn tk reps
    for i in "${!R_PVC[@]}"; do
      ns="${R_NS[$i]}"; local pvc="${R_PVC[$i]}" vs="${R_VS[$i]}"
      wn=$(echo "$pvc" | sed 's/^data-//; s/-[0-9]\+$//')
      tk="sts"; oc -n "$ns" get sts "$wn" &>/dev/null || tk="deploy"
      reps=$(oc -n "$ns" get "$tk" "$wn" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

      echo -ne "\n${R}Proceed Scale Down & CSI Replace for $ns/$pvc? (YES/no): ${NC}"; read -r ok
      [[ "$ok" != "YES" ]] && continue

      if ! oc -n "$ns" scale "$tk" "$wn" --replicas=0 2>/dev/null; then
        echo -e "${R}Scale down failed. Skipping.${NC}"; continue
      fi
      if ! wait_workload_pods_gone "$ns" "$wn"; then
        workload_wait_abort "$ns" "$tk" "$wn" "$reps" && continue
      fi

      local sc amodes req snap_req req_use
      sc=$(oc -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
      req=$(oc -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
      amodes=$(oc -n "$ns" get pvc "$pvc" -o json 2>/dev/null | jq -r '.spec.accessModes[]' 2>/dev/null | paste -sd, - || true)
      snap_req=$(oc -n "$ns" get volumesnapshot "$vs" -o jsonpath='{.status.restoreSize}' 2>/dev/null || true)
      req_use="$(max_qty "$req" "$snap_req")"; [[ -z "$req_use" ]] && req_use="${snap_req:-10Gi}"; [[ -z "$req_use" ]] && req_use="10Gi"
      [[ -z "$sc" || -z "$amodes" ]] && { echo -e "${R}Skip: no PVC spec.${NC}"; oc -n "$ns" scale "$tk" "$wn" --replicas="$reps" 2>/dev/null; continue; }

      oc -n "$ns" delete pvc "$pvc" --wait=true >/dev/null 2>&1 || true
      if ! oc apply -f - <<EOF 2>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $pvc, namespace: $ns }
spec:
  storageClassName: $sc
  accessModes: [${amodes//,/,\ }]
  resources: { requests: { storage: $req_use } }
  dataSource: { name: $vs, kind: VolumeSnapshot, apiGroup: snapshot.storage.k8s.io }
EOF
      then echo -e "${R}Failed to create PVC from snapshot. Scaling back up.${NC}"; oc -n "$ns" scale "$tk" "$wn" --replicas="$reps" 2>/dev/null; continue; fi
      echo -ne "  Waiting for PVC Bound... "
      for _ in {1..240}; do
        st=$(oc -n "$ns" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$st" == "Bound" ]] && { echo -e "${G}OK${NC}"; break; }; sleep 1
      done
      if ! oc -n "$ns" scale "$tk" "$wn" --replicas="$reps" 2>/dev/null; then
        echo -e "${R}Scale up failed. Fix manually.${NC}"
      else
        sleep 3; oc -n "$ns" patch "$tk" "$wn" --type='merge' -p "{\"spec\":{\"replicas\":$reps}}" 2>/dev/null
      fi
      write_log "RESTORE" "CSI replace $ns/$pvc from $vs"
      echo -e "${G}>>> CSI Replace done for $ns/$pvc${NC}"
    done
  fi

  SELECTED_STATUS=(); refresh_data; read -p "Done."
}

# --- UI (group by namespace) ---
draw_screen() {
  tput clear
  echo -e "${C}${B}>> PORTWORX COMMANDER V87 - STS-safe (STORK+CSI) <<${NC}"
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "SCOPE: ${B}ALL NAMESPACES${NC} | PX: ${B}${PX_NAMESPACE}/${PX_POD:0:15}...${NC} | FILTER(SC): ${B}${PX_SC_REGEX}${NC}"
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  printf "${B}%-3s %-4s %-16s %-24s %-4s %-4s %-4s %-14s %-14s %-10s %-8s${NC}\n" \
    "ID" "SEL" "NAMESPACE" "PVC NAME" "SCH" "MAN" "TOT" "LAST SNAP" "NEXT SNAP" "POLICY" "STATUS"
  echo -e "----------------------------------------------------------------------------------------------"

  local last_ns="" ns pvc
  for i in "${!ALL_KEY[@]}"; do
    ns="${ALL_NS[$i]}"; pvc="${ALL_PVC[$i]}"

    if [[ "$ns" != "$last_ns" ]]; then
      # group header line
      echo -e "${B}${M}-- Namespace: ${ns} --${NC}"
      last_ns="$ns"
    fi

    local sch_cnt man_cnt tot_cnt
    sch_cnt=$(count_stork_snaps "$ns" "$pvc"); [[ -z "$sch_cnt" ]] && sch_cnt=0
    man_cnt=$(count_csi_snaps "$ns" "$pvc");   [[ -z "$man_cnt" ]] && man_cnt=0
    tot_cnt=$((sch_cnt + man_cnt))

    local last_ts last_hms
    last_ts=$(get_last_snap_time "$ns" "$pvc")
    last_hms=$(fmt_hms "$last_ts")

    local scount policy next_hms
    scount=$(get_schedules_for_pvc "$ns" "$pvc" | wc -l | awk '{print $1}')
    policy="---"; next_hms="---"

    if [[ "$scount" -gt 1 ]]; then
      policy="MULTI"
      next_hms="---"
    elif [[ "$scount" -eq 1 ]]; then
      local sched_json next_ts
      sched_json=$(get_sched_for_pvc_one_json "$ns" "$pvc")
      policy=$(echo "$sched_json" | jq -r '.spec.schedulePolicyName // "---"' 2>/dev/null | sed 's/^p-//')
      next_ts=$(get_next_snap_time "$sched_json")
      if [[ -n "$next_ts" ]]; then
        next_hms=$(fmt_hms "$next_ts")
      else
        local sec epoch
        sec="$(policy_to_seconds "$policy")"
        epoch="$(to_epoch_utc "$last_ts")"
        [[ -n "$sec" && -n "$epoch" ]] && next_hms="$(fmt_hms_epoch "$((epoch + sec))")"
      fi
    fi

    local p_stat p_col
    if [[ "$sch_cnt" -gt 0 && "$man_cnt" -gt 0 ]]; then
      p_stat="Both"; p_col=$G
    elif [[ "$sch_cnt" -gt 0 ]]; then
      p_stat="Active"; p_col=$G
    elif [[ "$man_cnt" -gt 0 ]]; then
      p_stat="Manual"; p_col=$Y
    else
      p_stat="None"; p_col=$R
    fi

    local sel_box="[ ]"; [[ "${SELECTED_STATUS[$i]}" -eq 1 ]] && sel_box="${G}[x]${NC}"
    printf "%-3d %-13b %-16s %-24s %-4s %-4s %-4s %-14s %-14s %-10s ${p_col}%-8s${NC}\n" \
      "$((i+1))" "$sel_box" "${ns:0:16}" "${pvc:0:24}" "$sch_cnt" "$man_cnt" "$tot_cnt" "$last_hms" "$next_hms" "${policy:0:10}" "$p_stat"
  done

  if [[ ${#ALL_KEY[@]} -eq 0 ]]; then
    echo -e "  ${Y}(No PVCs match filter)${NC}"
    oc whoami -q &>/dev/null || echo -e "  ${Y}Tip: run 'oc login' if you haven't.${NC}"
  fi

  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "[${B}t${NC}] Select | [${B}h${NC}] Sched(STORK) | [${B}u${NC}] Un-sched | [${B}r${NC}] Restore | [${B}s${NC}] Snap(CSI) | [${B}c${NC}] Cleanup | [${B}q${NC}] Quit"
  echo -ne "\n${B}Action: ${NC}"
}

# --- Main Loop ---
refresh_data
while true; do
  draw_screen
  read -r -n 1 key
  echo ""
  case ${key,,} in
    t)
      echo -ne "\r${EL}${M}>>> Select ID(s) (e.g. '1 3') or 'a': ${NC}"
      read -r input
      if [[ "$input" == "a" ]]; then
        for i in "${!ALL_KEY[@]}"; do SELECTED_STATUS[$i]=1; done
      else
        for n in $input; do
          i=$((n-1))
          [[ $i -ge 0 && $i -lt ${#ALL_KEY[@]} ]] && {
            [[ ${SELECTED_STATUS[$i]} -eq 1 ]] && SELECTED_STATUS[$i]=0 || SELECTED_STATUS[$i]=1
          }
        done
      fi
      ;;
    h) set_schedule ;;
    u) unschedule_action ;;
    r) restore_pvc ;;
    s) manual_snap_csi ;;
    c) cleanup_action ;;
    "") refresh_data ;;
    q) tput clear; exit 0 ;;
  esac
done
