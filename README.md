# Portworx Ops Scripts

Scripts for **Portworx** on OpenShift/Kubernetes: snapshot/restore management and daily health checks. Each tool lives in its own directory with its own README.

| Tree | Script | Purpose |
|------|--------|---------|
| **[px-snapshot/](px-snapshot/)** | `px-snapshot.sh` | Interactive snapshot schedules (STORK), manual CSI snapshots, and STS-safe restore. |
| **[px-health-check/](px-health-check/)** | `px-health-check.sh` | Daily health dashboard: cluster status, pool utilization, alerts, pod readiness; exit code for cron/monitoring. |

---

## Quick links

- **Snapshot & restore:** [px-snapshot/README.md](px-snapshot/README.md) — features, usage, env vars, restore flow.
- **Health check:** [px-health-check/README.md](px-health-check/README.md) — features, usage, env vars, exit codes.

---

## Clone and run

```bash
git clone https://github.com/goasutlor/portworx.git
cd portworx/px-snapshot && ./px-snapshot.sh
cd ../px-health-check && ./px-health-check.sh
```

---

## License

Use at your own risk. Ensure you have backups and understand snapshot/restore and cluster access before running in production.
