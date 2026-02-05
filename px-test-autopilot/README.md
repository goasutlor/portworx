# px-test-autopilot

**Author:** Sontas Jiamsripong

Real-time **Portworx Autopilot demo dashboard** for OpenShift/ARO. Test **PVC**, **storage pool**, and **AutopilotRule** in one place: pick a pod (and its PVC), pick one or more AutopilotRules, then watch storage usage, ARO rule events, replica pools, and cluster status in a single screen. Includes an optional load generator to grow FS usage and trigger Autopilot resize.

Ideal for **implementers** who need to **showcase Autopilot**: you need some pre-config (e.g. deploy a pod with a Portworx PVC and create AutopilotRules), but once set up, this script gives a clear, real-time view suitable for demos.

---

## What it does

| Section | Description |
|--------|-------------|
| **[1] Storage layer** | PVC name, mount path, PVC size, filesystem size/used/use%. Alert (e.g. red) when use% exceeds threshold. |
| **[2] ARO – Rule events** | Selected AutopilotRule(s): state and **last transition events** from `oc describe` (e.g. ActiveActionsInProgress → ActiveActionsTaken). **Select 2+ rules** and see messages for all of them on the same screen. |
| **[3] Target storage pools** | Replica nodes for the volume: node IP, pool UUID, drive path (from `pxctl volume inspect`). |
| **[4] PX cluster summary** | All PX nodes with status; marks which nodes are replicas for the current volume. |
| **[5] Load generator** | Start `dd` inside the pod to consume space (trigger Autopilot resize) or clear test files. |

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
 > RULE: volume-resize-app-fio-gt50 | STATE: Active
    [ -      ] ActiveActionsPending => ActiveActionsInProgress
    [ -      ] ActiveActionsInProgress => ActiveActionsTaken

[3. TARGET STORAGE POOLS (DRILL DOWN)]
NODE_IP         POOL_UUID                                DRIVE_PATH
192.168.1.11   0c52e938-f05f-4553-b39d-adda846e7c91     /dev/mapper/3624a937093858f002fda406a00011712
192.168.1.12   d3ae4f1d-a20e-4502-8437-c7863b3438c4     /dev/mapper/3624a937093858f002fda406a00011713

[4. PX CLUSTER SUMMARY]
NODE_IP         NODE_NAME                STATUS     STORAGE_STATUS
192.168.1.10    node-1.cluster.local    Online     Up
192.168.1.12    node-3.cluster.local    Online     Up              (REPLICA)
192.168.1.11    node-2.cluster.local    Online     Up              (REPLICA)

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
  - One or more **AutopilotRules** (e.g. volume resize rules) already created.

---

## Usage

```bash
# Use project that has your app pod + PVC
oc project <your-project>

chmod +x px-test-autopilot.sh
./px-test-autopilot.sh
```

1. **Step 1:** Choose which **AutopilotRules** to monitor (e.g. `1 2` for rules 1 and 2). Both rules’ state and events are shown in [2] on the same screen.
2. **Step 2:** Choose the **target pod** (app with Portworx volume). The script resolves PVC and volume ID and starts the dashboard.
3. Optional: press **[l]** to generate load (enter GB) and **[c]** to remove test files.

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PX_NS` | `portworx-cwdc` | Portworx namespace (for `pxctl` and cluster summary). |
| `PX_FS_WARN_PCT` | `50` | FS use% above which the storage layer shows an alert. |
| `PX_NO_BLINK` | `0` | Set to `1` (or `y`/`Y`/`t`/`T`) to disable blink on high usage (use bold colour only). |

---

## Quick demo flow

1. Deploy a workload with a Portworx PVC and create AutopilotRules (e.g. resize when usage &gt; 50%).
2. Run `./px-test-autopilot.sh`, select the rule(s) and the pod.
3. Use **[l]** to add load and watch [1] use% and [2] ARO events in real time as Autopilot resizes the volume and pool.

---

## Files

- **`px-test-autopilot.sh`** – Main script.
- **`REVIEW.md`** – Internal review notes (optional read).
