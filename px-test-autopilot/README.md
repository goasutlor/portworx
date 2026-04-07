# px-test-autopilot

**Author:** Sontas Jiamsripong

Real-time **Portworx Autopilot demo dashboard** for OpenShift/ARO. Test **PVC**, **storage pool**, and **Autopilot** state in one place: pick a pod (and its PVC), optionally pick AutopilotRules for legacy fallback, then watch storage usage, per-PVC rule journey, replica pools, and cluster status in a single screen. Includes an optional load generator to grow FS usage and trigger Autopilot resize.

Ideal for **implementers** who need to **showcase Autopilot**: you need some pre-config (e.g. deploy a pod with a Portworx PVC and create AutopilotRules / AutopilotRuleObjects), but once set up, this script gives a clear, real-time view suitable for demos.

---

## What it does

| Section | Description |
|--------|-------------|
| **[1] Storage layer** | PVC name, mount path, PVC size, filesystem size/used/use%. Alert (e.g. red/blink) when use% exceeds threshold. |
| **[2] ARO – Rule events** | **Primary:** **AutopilotRuleObject** in the app namespace whose `metadata.name` matches the PVC’s **`spec.volumeName`** (same ID you see as `Vol:` in the header). Shows **RULE** (label), **STATE** (latest item), and a **full transition journey** from `status.items` (timestamp + transition), in a wide two-column layout. **Fallback:** if that object does not exist, uses selected **AutopilotRule(s)** and events from `oc describe autopilotrule` (shared/cluster-wide events, last 12). Step 1 rule selection is mainly for this fallback. |
| **[3] Target storage pools** | Replica sets for the volume from `pxctl volume inspect`: **Set**, node IP, pool UUID, drive path when present. On **local disk** / some PX layouts, **`DRIVE_PATH` may show `N/A`** because inspect output has no per-replica path line. Note clarifies this block is **volume replicas only** (per volume **HA**), not every node in the cluster. |
| **[4] PX cluster summary** | Parses **`pxctl status`** cluster summary: node IP, **SchedulerNodeName**, status, storage status; marks **(REPLICA)** for nodes in the volume’s replica set. Tolerates **PX-StoreV2** / multi-column `pxctl` output. |
| **[5] Load generator** | Start `dd` inside the pod to consume space (trigger Autopilot resize) or clear test files. |

### Behaviour notes (recent improvements)

- **Section [2] height:** The dashboard redraws from the top (`tput cup`) without clearing the whole screen. The journey block uses a **fixed row count** (`PX_ARO_JOURNEY_DISPLAY`, default 8) so when the history gets shorter, blank lines still overwrite older output and **text does not “leak” into [3]**.
- **Portworx pod / namespace:** The script resolves a **running** pod with `name=portworx` for `pxctl`. It tries `PX_NS`, then the current project, then common namespaces (e.g. `portworx-cwdc`, `portworx-cwdc-dev`, `kube-system`), then cluster-wide discovery. Override with **`PX_NS`** if needed.
- **`pxctl` path:** Tries `pxctl` on `PATH`, then **`/opt/pwx/bin/pxctl`** inside the Portworx pod.
- **Section [4]:** Cluster file is read with a correct shell redirect so the UI **does not hang** waiting on stdin.

Dashboard refreshes every **5 seconds** in-place (no full-screen clear). Hotkeys: **[t]** Targets, **[r]** Rules, **[l]** Gen load, **[c]** Clear, **[q]** Quit.

---

## Example dashboard

```
====================================================================================================
 STATUS: PX-ALERT-MONITOR | Project: my-app-prod | Time: 20:25:20
 Pod: demo-pod-0 | Mount: /data | Vol: pvc-a1b2c3d4-e5f6-7890-abcd-ef1234567890
====================================================================================================
[1. STORAGE LAYER]
PVC_NAME                  MOUNT           PVC_SIZE   FS_SIZE    FS_USED    FS_USE%
data-demo-pod-0           /data           155Gi      153G       61G        40%
----------------------------------------------------------------------------------------------------
[2. ARO – RULE EVENTS]

 > ARO:   pvc-a1b2c3d4-e5f6-7890-abcd-ef1234567890
   RULE:  volume-resize-app-fio-gt50
   STATE: Normal

    WHEN (UTC)               STATE TRANSITION
    -----------------------  ------------------------------------------------------------------
    2026-04-07 14:27:54      => Initializing
    2026-04-07 14:28:05      Initializing => Normal
    ...

[3. TARGET STORAGE POOLS (DRILL DOWN)]
SET    NODE_IP         POOL_UUID                                DRIVE_PATH
0      192.168.1.12    d3ae4f1d-a20e-4502-8437-c7863b3438c4     /dev/mapper/...
0      192.168.1.11    0c52e938-f05f-4553-b39d-adda846e7c91     /dev/mapper/...
 Note: This section shows volume replicas only (HA=2), not all cluster nodes.

[4. PX CLUSTER SUMMARY]
NODE_IP         NODE_NAME                                     STATUS     STORAGE_STATUS
192.168.1.10    node-1.cluster.local                       Online     Up
192.168.1.12    node-3.cluster.local                       Online     Up              (REPLICA)
192.168.1.11    node-2.cluster.local                       Online     Up              (REPLICA)

[5. LOAD GENERATOR]
 STATUS: IDLE | Waiting for command...

----------------------------------------------------------------------------------------------------
 [t] Targets | [r] Rules | [l] Gen Load | [c] Clear | [q] Quit
```

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
| `PX_NS` | `portworx-cwdc` | Portworx namespace hint (first try); script may auto-detect another namespace if no `name=portworx` pod is found there. |
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
