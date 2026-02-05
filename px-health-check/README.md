# px-health-check.sh

Daily **health dashboard** for Portworx on OpenShift/Kubernetes: cluster status, licence expiry, storage pool utilization, PVC/PV inventory, critical alerts, and pod readiness. Designed for ops to run once per day (e.g. cron); exit code and a one-line summary allow automation and monitoring.

---

## Features

| Feature | Description |
|--------|-------------|
| **Cluster & entitlements** | Cluster ID, Portworx version, storage node count, licence expiry date. |
| **Storage pool utilization** | Per-node capacity, used, **UTIL%** (computed), Online/Offline status. |
| **Volume & PVC inventory** | Total PVCs, PVs, Released (orphaned) PVs, detached volumes. |
| **Critical alerts** | Recent ALARM/CRITICAL from `pxctl alerts` with time in BKK (GMT+7). |
| **Pod readiness** | All Portworx pods in namespace: Ready x/y and Running; lists faulty pods and suggests debug commands. |
| **Ops warnings** | Licence < 30 days, pool utilization ≥ threshold, Released PVs. |
| **Exit code** | `0` = healthy, `1` = degraded (pods not ready), `2` = discovery/pxctl failed. |
| **One-line summary** | `PX_HEALTH_CHECK_RESULT=OK|DEGRADED|FAIL exit_code=... runtime_sec=...` for grep/cron. |
| **Optional log file** | Set `LOG_DIR` to append the report to `logs/px-health-check_YYYYMMDD.log`. |

---

## Requirements

- OpenShift/Kubernetes with Portworx.
- **`oc`** (or `kubectl`) in `PATH`, logged in.
- **Bash** (script uses `pxctl status` and `pxctl alerts` via `oc exec`).

---

## Usage

```bash
chmod +x px-health-check.sh
./px-health-check.sh
echo "Exit: $?"
```

**With log file (e.g. for daily runs):**

```bash
LOG_DIR=./logs ./px-health-check.sh
```

**Cron (e.g. 08:00 daily):**

```bash
0 8 * * * /path/to/px-health-check/px-health-check.sh || echo "Portworx healthcheck failed"
```

**Check result from script/monitoring:**

```bash
./px-health-check.sh | tee -a daily.log
grep PX_HEALTH_CHECK_RESULT daily.log | tail -1
```

---

## Example output

(Look and feel only; names and IPs below are generic.)

```
PORTWORX ENTERPRISE OPERATIONAL DASHBOARD v51.0
Report Generated: 2026-02-05 20:27:20 (BKK GMT+7)
Namespace: portworx | Pod: px-cluster-abc123-def456-7890-abcdef123456-5kggd
====================================================================================
I. CLUSTER & ENTITLEMENTS
  Storage nodes            : 3
  Cluster Identifier       : px-cluster-abc123-def456-7890-abcdef123456
  Expiry Date              : 2026-02-21 (In 16 days)
  ⚠ WARNING: Licence expires in 16 days. Plan renewal.
------------------------------------------------------------------------------------
II. STORAGE POOL UTILIZATION
DATA IP         |     CAPACITY |         USED |    UTIL% | STATUS
------------------------------------------------------------------------------------
192.168.1.10    |     10.0 TiB |       54 GiB |     0.5% | Online
192.168.1.12    |     10.0 TiB |       96 GiB |     0.9% | Online
192.168.1.11    |     10.0 TiB |      104 GiB |     1.0% | Online
------------------------------------------------------------------------------------
III. VOLUME & PVC INVENTORY
  Total PVCs (All Namespaces)              : 23
  Total PVs (Cluster Wide)                 : 23
  Total Released PVs (Orphaned)            : 0
  Total Detached Volumes (Portworx)        : 0
------------------------------------------------------------------------------------
IV. CRITICAL SYSTEM ALERTS (LOCAL GMT+7)
TIME (BKK)      | ALERT TYPE             | INSIGHT
02/02 08:47 | RebalanceJobFinished   | UTC 2026 Feb 2 01:47:01 rebalance: job finished
02/02 10:57 | RebalanceJobFinished   | UTC 2026 Feb 2 03:57:36 rebalance: job finished
02/02 10:57 | RebalanceJobStarted    | UTC 2026 Feb 2 03:57:36 rebalance: job started on node a1b2c
02/02 11:55 | RebalanceJobFinished   | UTC 2026 Feb 2 04:55:48 rebalance: job finished
02/02 11:55 | RebalanceJobStarted    | UTC 2026 Feb 2 04:55:48 rebalance: job started on node a1b2c
02/02 15:37 | NodeStateChange        | UTC 2026 Feb 2 08:37:41 Node is not in quorum. Waiting to con
02/03 12:39 | NodeStateChange        | UTC 2026 Feb 3 05:39:20 Node is not in quorum. Waiting to con
02/04 16:22 | CallHomeFailure        | UTC 2026 Feb 2 08:40:05 failed to send callhome data. meterin
02/04 18:03 | NodeStateChange        | UTC 2026 Feb 4 11:03:04 Node is not in quorum. Waiting to con
02/05 15:53 | BaseAgentRegistrationFailed | UTC 2026 Feb 2 08:40:16 Failed to register base agent. You ma
------------------------------------------------------------------------------------
V. POD ORCHESTRATION INVENTORY (READY CHECK)
POD NAME                                                | READY      | HEALTH STATUS
------------------------------------------------------------------------------------
autopilot-55699fdc54-4f6rb                              | 1/1        | ✔ HEALTHY
portworx-api-bkrbw                                      | 2/2        | ✔ HEALTHY
portworx-api-qs8fj                                      | 2/2        | ✔ HEALTHY
portworx-api-wrzlk                                      | 2/2        | ✔ HEALTHY
portworx-kvdb-9pz64                                     | 1/1        | ✔ HEALTHY
portworx-kvdb-pmk6q                                     | 1/1        | ✔ HEALTHY
portworx-kvdb-wdsgf                                     | 1/1        | ✔ HEALTHY
portworx-operator-6ffcc6677f-rvgpq                      | 1/1        | ✔ HEALTHY
px-cluster-abc123-def456-7890-abcdef123456-5kggd         | 1/1        | ✔ HEALTHY
px-cluster-abc123-def456-7890-abcdef123456-nmh46         | 1/1        | ✔ HEALTHY
px-cluster-abc123-def456-7890-abcdef123456-p5tfz         | 1/1        | ✔ HEALTHY
px-csi-ext-f698d4c9b-br5zn                              | 4/4        | ✔ HEALTHY
px-csi-ext-f698d4c9b-j5jn5                              | 4/4        | ✔ HEALTHY
px-csi-ext-f698d4c9b-lxz56                              | 4/4        | ✔ HEALTHY
px-plugin-755d44459d-g5cg2                              | 1/1        | ✔ HEALTHY
px-plugin-755d44459d-k8bq4                              | 1/1        | ✔ HEALTHY
px-plugin-proxy-58c8865887-fj4vr                        | 1/1        | ✔ HEALTHY
stork-5d79f877b6-474hq                                  | 1/1        | ✔ HEALTHY
stork-5d79f877b6-7c7vs                                  | 1/1        | ✔ HEALTHY
stork-5d79f877b6-b89rc                                  | 1/1        | ✔ HEALTHY
stork-scheduler-7b55db46b8-4nl6m                         | 1/1        | ✔ HEALTHY
stork-scheduler-7b55db46b8-qf2hc                         | 1/1        | ✔ HEALTHY
stork-scheduler-7b55db46b8-s4skf                         | 1/1        | ✔ HEALTHY
------------------------------------------------------------------------------------
FINAL CONCLUSION:
  ✔ CLUSTER HEALTHY: All pods fully ready (23/23).
------------------------------------------------------------------------------------
Runtime: 2s
PX_HEALTH_CHECK_RESULT=OK exit_code=0 runtime_sec=2
Log written to: ./logs/px-health-check_20260205.log
====================================================================================
[ops@host ~]$
```

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_DIR` | `./logs` | Directory for daily log; report appended to `px-health-check_YYYYMMDD.log`. Set empty to disable. |
| `POOL_UTIL_WARN` | `80` | Warn when any storage pool utilization ≥ this percentage. |

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Cluster healthy (all Portworx pods ready and running). |
| `1` | Degraded (one or more pods not ready or not running). |
| `2` | Discovery failed (Portworx namespace/pod not found or `pxctl status` failed). |

---

## Files

- **`px-health-check.sh`** – Main script (in this directory).
- **`./logs/px-health-check_YYYYMMDD.log`** – Daily report when `LOG_DIR` is set.

---

## License

Use at your own risk. Ensure you have backups and understand cluster access before running in production.
