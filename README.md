# Portworx Ops Scripts

Scripts for **Portworx** on OpenShift/Kubernetes: snapshot/restore, health checks, volume placement, and daily ops. Each tool lives in its own directory with its own README.

| Tree | Script | Purpose |
|------|--------|---------|
| **[px-snapshot/](px-snapshot/)** | `px-snapshot.sh` | Interactive snapshot schedules (STORK), manual CSI snapshots, and STS-safe restore. |
| **[px-health-check/](px-health-check/)** | `px-health-check.sh` | Daily health dashboard: cluster status, pool utilization, alerts, pod readiness; exit code for cron/monitoring. |
| **[px-house-keeping/](px-house-keeping/)** | `px-house-keeping.sh` | Clean up Released PVs and orphaned Portworx volumes (for clusters using ReclaimPolicy: Retain). |
| **[px-volume-placement/](px-volume-placement/)** | `px-volume-placement.sh` | Scan PVCs by StorageClass, analyze LOCAL/REMOTE placement, organize replicas to Pod node, increase/decrease Rep. |
| **[px-test-autopilot/](px-test-autopilot/)** | `px-test-autopilot.sh` | Monitor Portworx PVCs, replica health, and Autopilot rule transitions. |

---

## Quick links

- **Snapshot & restore:** [px-snapshot/README.md](px-snapshot/README.md) — features, usage, env vars, restore flow.
- **Health check:** [px-health-check/README.md](px-health-check/README.md) — features, usage, env vars, exit codes.
- **Housekeeping (Retain):** [px-house-keeping/README.md](px-house-keeping/README.md) — why Retain needs housekeeping, usage, phases.
- **Volume placement:** [px-volume-placement/README.md](px-volume-placement/README.md) — scan, organize, increase/decrease Rep.
- **Autopilot monitor:** [px-test-autopilot/README.md](px-test-autopilot/README.md) — PVC and Autopilot rule tracking.

---

## Changelog

### [1.0.06022026] – 2026-02-06

#### Added
- **px-volume-placement** – New tool to scan PVCs by StorageClass, show LOCAL/REMOTE placement vs Pod node, organize replicas to Pod node (Organize), increase/decrease Rep via `ha-update`. Menu: Rescan, Cluster state, Pool balance, Select PVCs, Organize, Change SC, Increase/Decrease Rep, Back, Quit.
- **px-test-autopilot** – Autopilot monitoring tool (existing; versioned).

#### Changed
- **All scripts** – Version set to `1.0.06022026`.
- **px-snapshot** – Replaced internal V87 with version tag `1.0.06022026`.

#### px-volume-placement highlights
- StorageClass selectable at runtime (or `PX_SC` env).
- Organize: add replica on Pod node, remove from non-Pod node (Rep=2 strategy).
- Increase Rep: add replica on chosen node; Decrease Rep: remove from chosen node.
- Select/Unselect feedback; Cancel (0/b) in sub-menus; [b] Back to refresh view.
- Auto-rescan after Organize/Increase/Decrease Rep.
- Warning reminders before risky actions (Organize, Decrease Rep, Rep=1).

---

## Clone and run

```bash
git clone https://github.com/goasutlor/portworx.git
cd portworx/px-snapshot && ./px-snapshot.sh
cd ../px-health-check && ./px-health-check.sh
cd ../px-house-keeping && ./px-house-keeping.sh
```

---

## License

Use at your own risk. Ensure you have backups and understand snapshot/restore and cluster access before running in production.
