# Portworx Snapshot Commander (px-snapshot.sh)

Interactive CLI for managing **Portworx** volume snapshots on OpenShift/Kubernetes. Supports both **STORK** (scheduled) and **CSI** (manual) snapshots, with **STS-safe restore** for StatefulSets and Deployments.

---

## Features

| Feature | Description |
|--------|-------------|
| **Cluster-wide PVC list** | Scans all namespaces; shows only PVCs using Portworx StorageClass (configurable regex). |
| **STORK schedules** | Create interval, daily, weekly, or monthly snapshot schedules with local time (Asia/Bangkok) → UTC conversion. |
| **Manual CSI snapshots** | One-off CSI `VolumeSnapshot` for selected PVC(s). |
| **STS-safe restore** | Restore from STORK or CSI snapshots with correct scale-down/wait/restore/scale-up for **StatefulSets** and Deployments (waits for pod names like `workload-0`, `workload-1`). |
| **Restore sources** | Restore from **STORK** (schedule) or **CSI** (manual) snapshots; CSI supports **clone** (new PVC) or **replace** (in-place). |
| **Multi-workload STORK restore** | When multiple PVCs are selected, groups by namespace and workload and runs one scale/restore/scale cycle per workload. |
| **Timeout handling** | If pods do not terminate in time, prompts to abort (and scale back up) or continue anyway. |
| **Cleanup** | Remove schedules and/or STORK + CSI snapshots for selected PVC(s) (requires typing `CLEAN`). |
| **Logging** | Actions logged under `./logs/px_commander_YYYYMMDD.log`. |

---

## Requirements

- **OpenShift/Kubernetes** cluster with Portworx and STORK/CSI snapshot support.
- **`oc`** (or `kubectl`) in `PATH` and logged in.
- **`jq`** installed.
- **Bash** 4+ (for arrays and `mapfile`).

---

## Usage

### 1. Run the script

```bash
chmod +x px-snapshot.sh
./px-snapshot.sh
```

Or:

```bash
bash px-snapshot.sh
```

### 2. Optional environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `S_CLASS` | `px-csi-snapclass` | VolumeSnapshotClass name for CSI snapshots. |
| `PX_SC_REGEX` | `.*(px\|portworx).*` | Regex to filter PVCs by StorageClassName (only matching PVCs are listed). |

Example (narrow filter):

```bash
PX_SC_REGEX=".*portworx.*" ./px-snapshot.sh
```

### 3. Main menu

- **[t] Select** – Toggle selection by ID (e.g. `1 3 5`) or `a` for all.
- **[h] Sched(STORK)** – Add STORK schedule (interval/daily/weekly/monthly) for selected PVC(s).
- **[u] Un-sched** – Remove STORK schedule(s) for selected PVC(s); snapshots are kept.
- **[r] Restore** – Restore selected PVC(s) from STORK or CSI snapshot (with STS-safe scale down/up).
- **[s] Snap(CSI)** – Create manual CSI snapshot for selected PVC(s).
- **[c] Cleanup** – Delete schedules and STORK + CSI snapshots for selected PVC(s) (must type `CLEAN`).
- **[q] Quit** – Exit.

---

## Restore flow

1. Select one or more PVCs with **[t]**, then press **[r]**.
2. For each selected PVC you choose:
   - **S** – Restore from a **STORK** (schedule) snapshot.
   - **C** – Restore from a **CSI** (manual) snapshot; then choose:
     - **1** – **Clone**: create a new PVC from snapshot (no scale down).
     - **2** – **Replace**: scale down workload → delete PVC → create PVC from snapshot → scale up (PV should have `reclaimPolicy: Retain`).
3. For STORK restore you confirm once with **YES**; the script groups by workload and runs one scale-down → restore(s) → scale-up per workload.
4. For CSI replace you confirm per PVC; same STS-safe scale/wait/scale-up logic applies.

---

## Files

- **`px-snapshot.sh`** – Main script.
- **`./logs/px_commander_YYYYMMDD.log`** – Daily action log (created automatically).

---

## License

Use at your own risk. Ensure you have backups and understand snapshot/restore semantics before running in production.
