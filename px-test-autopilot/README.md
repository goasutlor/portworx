# px-test-autopilot

**Author:** Sontas Jiamsripong

Real-time **Portworx Autopilot demo dashboard** for OpenShift/ARO. Test **PVC**, **storage pool**, and **Autopilot** state in one place: pick a pod (and its PVC), optionally pick AutopilotRules for legacy fallback, then watch storage usage, per-PVC rule journey, replica pools, and cluster status in a single screen. Includes an optional load generator to grow FS usage and trigger Autopilot resize.

Ideal for **implementers** who need to **showcase Autopilot**: you need some pre-config (e.g. deploy a pod with a Portworx PVC and create AutopilotRules / AutopilotRuleObjects), but once set up, this script gives a clear, real-time view suitable for demos.

---

## What it does

| Section | Description |
|--------|-------------|
| **[1] Storage layer** | PVC name, mount path, PVC size, filesystem size/used/use%. Alert (e.g. red/blink) when use% exceeds threshold. |
| **[2] ARO – Rule events** | **Primary:** **AutopilotRuleObject** in the app namespace whose `metadata.name` matches the PVC’s **`spec.volumeName`** (`Vol:` in the header). **RULE** / **STATE** / journey come from `oc describe autopilotruleobjects` (sorted by time). The table shows the **last `PX_ARO_JOURNEY_DISPLAY` rows** (default 8) in a fixed-height block so redraws do not smear into [3]. **Fallback:** if that object does not exist, uses selected **AutopilotRule(s)** and `oc describe autopilotrule` events (last 12, same display cap). |
| **[3] Target storage pools** | Replica sets for the volume from `pxctl volume inspect`: **Set**, node IP, pool UUID, drive path when present. On **local disk** / some PX layouts, **`DRIVE_PATH` may show `N/A`** because inspect output has no per-replica path line. Note clarifies this block is **volume replicas only** (per volume **HA**), not every node in the cluster. |
| **[4] PX cluster summary** | Parses **`pxctl status`** cluster summary: node IP, **SchedulerNodeName**, status, storage status; marks **(REPLICA)** for nodes in the volume’s replica set. Tolerates **PX-StoreV2** / multi-column `pxctl` output. |
| **[5] Load generator** | Start `dd` inside the pod to consume space (trigger Autopilot resize) or clear test files. |

### Behaviour notes (recent improvements)

- **Section [2] height:** The dashboard redraws from the top (`tput cup`) without clearing the whole screen. The journey block uses a **fixed row count** (`PX_ARO_JOURNEY_DISPLAY`, default 8) so when the history gets shorter, blank lines still overwrite older output and **text does not “leak” into [3]**.
- **Portworx pod / namespace:** The script resolves a **running** pod with `name=portworx` for `pxctl`. It tries `PX_NS`, then the current project, then common namespaces (e.g. `portworx`, `kube-system`, `openshift-storage`), then cluster-wide discovery. Override with **`PX_NS`** if needed.
- **`pxctl` path:** Tries `pxctl` on `PATH`, then **`/opt/pwx/bin/pxctl`** inside the Portworx pod.
- **Section [4]:** Cluster file is read with a correct shell redirect so the UI **does not hang** waiting on stdin.

Dashboard refreshes every **5 seconds** in-place (no full-screen clear). Hotkeys: **[t]** Targets, **[r]** Rules, **[l]** Gen load, **[c]** Clear, **[q]** Quit.

---

## Example dashboard

All names, addresses, UUIDs, and timestamps below are **synthetic placeholders** for documentation only (not real customer or cluster data).

```
====================================================================================================
 STATUS: PX-ALERT-MONITOR | Project: example-namespace | Time: 12:34:56
 Pod: demo-workload-0 | Mount: /data | Vol: pvc-00000000-1111-2222-3333-444444444444
====================================================================================================
[1. STORAGE LAYER]
PVC_NAME                  MOUNT           PVC_SIZE   FS_SIZE    FS_USED    FS_USE%
data-demo-workload-0      /data           100Gi      99G        40G        41%
----------------------------------------------------------------------------------------------------
[2. ARO – RULE EVENTS]

 > ARO:   pvc-00000000-1111-2222-3333-444444444444
   RULE:  volume-resize-example-rule
   STATE: Normal

    WHEN (UTC)                   STATE TRANSITION
    -----------------------      ------------------------------------------------------------------
    2030-06-15 10:00:00          => Initializing
    2030-06-15 10:00:10          Initializing => Normal
    ... (last PX_ARO_JOURNEY_DISPLAY rows, e.g. 8)

[3. TARGET STORAGE POOLS (DRILL DOWN)]
SET    NODE_IP         POOL_UUID                                DRIVE_PATH
0      198.51.100.11   00000000-0000-4000-8000-000000000001     /dev/mapper/...
0      198.51.100.12   00000000-0000-4000-8000-000000000002     N/A
 Note: This section shows volume replicas only (HA=2), not all cluster nodes.

[4. PX CLUSTER SUMMARY]
NODE_IP         NODE_NAME                                     STATUS     STORAGE_STATUS
198.51.100.10   worker-a.demo.example.internal                Online     Up
198.51.100.12   worker-c.demo.example.internal                Online     Up              (REPLICA)
198.51.100.11   worker-b.demo.example.internal                Online     Up              (REPLICA)

[5. LOAD GENERATOR]
 STATUS: IDLE | Waiting for command...

----------------------------------------------------------------------------------------------------
 [t] Targets | [r] Rules | [l] Gen Load | [c] Clear | [q] Quit
```

IPs use **TEST-NET-2** (`198.51.100.0/24`, RFC 5737) reserved for documentation only.

---

## Requirements

- **OpenShift/ARO** with Portworx and Autopilot enabled.
- **`oc`** in `PATH`, logged in; **Bash**.
- **Pre-config:**
  - At least one **running pod** in the current project that uses a **Portworx PVC**.
  - **AutopilotRuleObject** resources (per volume) are **recommended** for accurate section [2] (name = PVC `spec.volumeName`, namespace = PVC namespace). If your cluster only exposes **AutopilotRule** + Events, use Step 1 to select rules for the legacy path.

---

## Usage

```bash
# Use project that has your app pod + PVC
oc project <your-project>

chmod +x px-test-autopilot.sh
./px-test-autopilot.sh
```

1. **Step 1:** Choose **AutopilotRules** to monitor **when AutopilotRuleObject is not used** (fallback: `oc describe autopilotrule` events). If an ARO exists for the selected volume, section [2] uses it automatically and ignores which rules you picked here.
2. **Step 2:** Choose the **target pod** (app with Portworx volume). The script resolves PVC, volume ID (`spec.volumeName`), and Portworx context, then starts the dashboard.
3. Optional: press **[l]** to generate load (enter GB) and **[c]** to remove test files.

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PX_NS` | `portworx` | Portworx namespace hint (first try); script may auto-detect another namespace if no `name=portworx` pod is found there. Set to your environment’s Portworx namespace if different. |
| `PX_FS_WARN_PCT` | `50` | FS use% above which the storage layer shows an alert. |
| `PX_NO_BLINK` | `0` | Set to `1` (or `y`/`Y`/`t`/`T`) to disable blink on high usage (use bold colour only). |
| `PX_ARO_JOURNEY_MAX` | `30` | Max transition lines read from the ARO after sort (before display window). Set to **`0`** for unlimited. |
| `PX_ARO_JOURNEY_DISPLAY` | `8` | **Fixed number of rows** for the [2] journey table (shows the **last N** transitions). Padding clears leftover lines on redraw so old text does not appear under [3]. Set to **`0`** to show all parsed lines (can grow tall and leave ghosts if the list shrinks). |

---

## Quick demo flow

1. Deploy a workload with a Portworx PVC and create Autopilot rules (e.g. resize when usage &gt; 50%).
2. Run `./px-test-autopilot.sh`, select rule(s) if you rely on legacy describe, then select the pod.
3. Use **[l]** to add load and watch [1] use% and [2] transitions in real time as Autopilot resizes the volume and pool.

---

## Files

- **`px-test-autopilot.sh`** – Main script.
- **`REVIEW.md`** – Internal review notes (optional read).
