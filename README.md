# Portworx Ops Scripts

Scripts for **Portworx** on OpenShift/Kubernetes: snapshot/restore management and daily health checks.

| Script | Purpose |
|--------|---------|
| **px-snapshot.sh** | Interactive snapshot schedules (STORK), manual CSI snapshots, and STS-safe restore. |
| **px-health-check.sh** | Daily health dashboard: cluster status, pool utilization, alerts, pod readiness; exit code for cron/monitoring. |

---

# px-snapshot.sh

Interactive CLI for managing **Portworx** volume snapshots. Supports both **STORK** (scheduled) and **CSI** (manual) snapshots, with **STS-safe restore** for StatefulSets and Deployments.

## Features

| Feature | Description |
|--------|-------------|
| **Cluster-wide PVC list** | Scans all namespaces; shows only PVCs using Portworx StorageClass (configurable regex). |
| **STORK schedules** | Create interval, daily, weekly, or monthly snapshot schedules with local time (Asia/Bangkok) → UTC conversion. |
| **Manual CSI snapshots** | One-off CSI `VolumeSnapshot` for selected PVC(s). |
| **STS-safe restore** | Restore from STORK or CSI snapshots with correct scale-down/wait/restore/scale-up for **StatefulSets** and Deployments. |
| **Restore sources** | Restore from **STORK** (schedule) or **CSI** (manual) snapshots; CSI supports **clone** (new PVC) or **replace** (in-place). |
| **Multi-workload STORK restore** | Groups by namespace and workload; one scale/restore/scale cycle per workload. |
| **Timeout handling** | If pods do not terminate in time, prompts to abort (and scale back up) or continue. |
| **Cleanup** | Remove schedules and/or STORK + CSI snapshots for selected PVC(s) (requires typing `CLEAN`). |
| **Logging** | Actions logged under `./logs/px_commander_YYYYMMDD.log`. |

## Requirements

- OpenShift/Kubernetes with Portworx and STORK/CSI snapshot support.
- **`oc`** (or `kubectl`) in `PATH`, logged in.
- **`jq`** installed.
- **Bash** 4+.

## Usage

```bash
chmod +x px-snapshot.sh
./px-snapshot.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `S_CLASS` | `px-csi-snapclass` | VolumeSnapshotClass for CSI snapshots. |
| `PX_SC_REGEX` | `.*(px\|portworx).*` | Regex to filter PVCs by StorageClassName. |

**Menu:** [t] Select | [h] Sched(STORK) | [u] Un-sched | [r] Restore | [s] Snap(CSI) | [c] Cleanup | [q] Quit

---

# px-health-check.sh

Daily **health dashboard** for Portworx: cluster status, licence expiry, storage pool utilization, PVC/PV inventory, critical alerts, and pod readiness. Designed for ops to run once per day (e.g. cron); exit code and a one-line summary allow automation and monitoring.

## Features

| Feature | Description |
|--------|-------------|
| **Cluster & entitlements** | Cluster ID, Portworx version, storage node count, licence expiry date. |
| **Storage pool utilization** | Per-node capacity, used, **UTIL%** (computed), Online/Offline status. |
| **Volume & PVC inventory** | Total PVCs, PVs, Released (orphaned) PVs, detached volumes. |
| **Critical alerts** | Recent ALARM/CRITICAL from `pxctl alerts` with time in BKK (GMT+7). |
| **Pod readiness** | All Portworx pods in namespace: Ready x/y and Running; lists faulty pods and suggests debug commands. |
| **Ops warnings** | Licence &lt; 30 days, pool utilization ≥ threshold, Released PVs. |
| **Exit code** | `0` = healthy, `1` = degraded (pods not ready), `2` = discovery/pxctl failed. |
| **One-line summary** | `PX_HEALTH_CHECK_RESULT=OK|DEGRADED|FAIL exit_code=... runtime_sec=...` for grep/cron. |
| **Optional log file** | Set `LOG_DIR` to append the report to `logs/px-health-check_YYYYMMDD.log`. |

## Requirements

- OpenShift/Kubernetes with Portworx.
- **`oc`** (or `kubectl`) in `PATH`, logged in.
- **Bash** (script uses `pxctl status` and `pxctl alerts` via `oc exec`).

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
0 8 * * * /path/to/px-health-check.sh || echo "Portworx healthcheck failed"
```

**Check result from script/monitoring:**

```bash
./px-health-check.sh | tee -a daily.log
grep PX_HEALTH_CHECK_RESULT daily.log | tail -1
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_DIR` | `./logs` | Directory for daily log; report appended to `px-health-check_YYYYMMDD.log`. Set empty to disable. |
| `POOL_UTIL_WARN` | `80` | Warn when any storage pool utilization ≥ this percentage. |

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Cluster healthy (all Portworx pods ready and running). |
| `1` | Degraded (one or more pods not ready or not running). |
| `2` | Discovery failed (Portworx namespace/pod not found or `pxctl status` failed). |

---

## Files in this repo

| File | Description |
|------|-------------|
| **px-snapshot.sh** | Snapshot/restore CLI. |
| **px-health-check.sh** | Health check dashboard and exit-code report. |
| **README.md** | This file. |

**Generated at runtime (optional):**

- `./logs/px_commander_YYYYMMDD.log` – px-snapshot.sh action log.
- `./logs/px-health-check_YYYYMMDD.log` – px-health-check.sh daily report (when `LOG_DIR` is set).

---

## License

Use at your own risk. Ensure you have backups and understand snapshot/restore and cluster access before running in production.
