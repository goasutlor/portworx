# Portworx Ops Scripts

Scripts for **Portworx** on OpenShift/Kubernetes: snapshot/restore management and daily health checks. Each tool lives in its own directory with its own README.

| Tree | Script | Purpose |
|------|--------|---------|
| **[px-snapshot/](px-snapshot/)** | `px-snapshot.sh` | Interactive snapshot schedules (STORK), manual CSI snapshots, and STS-safe restore. |
| **[px-health-check/](px-health-check/)** | `px-health-check.sh` | Daily health dashboard: cluster status, pool utilization, alerts, pod readiness; exit code for cron/monitoring. |
| **[px-house-keeping/](px-house-keeping/)** | `px-house-keeping.sh` | Clean up Released PVs and orphaned Portworx volumes (for clusters using ReclaimPolicy: Retain). |

---

## Quick links

- **Snapshot & restore:** [px-snapshot/README.md](px-snapshot/README.md) — features, usage, env vars, restore flow.
- **Health check:** [px-health-check/README.md](px-health-check/README.md) — features, usage, env vars, exit codes.
- **Housekeeping (Retain):** [px-house-keeping/README.md](px-house-keeping/README.md) — why Retain needs housekeeping, usage, phases.

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
