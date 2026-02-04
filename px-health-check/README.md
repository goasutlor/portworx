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
