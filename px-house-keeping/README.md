# px-house-keeping.sh

**AUTHOR: Sontas Jiamsripong**

Script to clean up **Released** PVs and **Orphaned** Portworx volumes. Intended for clusters where PVs use **ReclaimPolicy: Retain**, so that reclaiming space and removing stale references is done in a controlled, auditable way instead of manual steps per volume.

---

## Why housekeeping when using Retain?

When you set **ReclaimPolicy** to **Retain** on PersistentVolumes:

- **Benefit:** If someone accidentally deletes a PVC (or the namespace), the PV and the underlying data are **not** deleted. The PV stays in phase **Released** and the data remains on storage. That protects you from human error and avoids data loss that would happen with **ReclaimPolicy: Delete**.
- **Trade-off:** The cluster does **not** automatically reclaim that storage. You need a **manual process** to:
  1. Decide which Released PVs (and any orphaned Portworx volumes) are safe to remove.
  2. Delete the Released PVs so they no longer reference the volumes.
  3. Clean up any orphaned volumes in Portworx so the space can be reused.

Doing this **by hand for each volume** is complex and involves many steps (find PV → check volume → delete PV → find orphan → detach/delete volume, etc.). This script **simplifies that for Operations**: it scans all Portworx volumes, shows a single audit table (Bound / Released / Orphaned), and then guides you through **Phase 1** (delete Released PVs) and **Phase 2** (delete orphaned PX volumes) so you can reclaim space in a controlled way without hunting for each item manually.

---

## Features

| Feature | Description |
|--------|-------------|
| **Audit table** | Lists all Portworx volumes with namespace, PV name, PVC name, PX state, and PV phase (Bound / Released). |
| **Orphan detection** | Volumes that have no matching PV (e.g. after PV was deleted) are shown as **Orphaned (No PV)**. |
| **Phase 1** | Option to delete **Released** PVs (releases the K8s reference so the volume can become “orphaned” and then be cleaned in Phase 2). |
| **Phase 2** | Option to **force-delete** orphaned Portworx volumes (permanent; reclaims space). |
| **Namespace discovery** | If no namespace is given, the script tries common PX namespaces (portworx-cwdc, portworx-tls2, portworx, kube-system) or any namespace with a running PX pod. |
| **Optional audit log** | Set `LOG_DIR` to write an audit log of the run (e.g. `logs/px-housekeeping_YYYYMMDD.log`). |
| **Safe exit** | Temp files are removed on exit (including when the script is interrupted). |

---

## Requirements

- OpenShift/Kubernetes cluster with **Portworx**.
- **`oc`** (or `kubectl`) in `PATH`, logged in with access to list PVs and to exec into the Portworx pod.
- **Bash**.

---

## Usage

```bash
chmod +x px-house-keeping.sh
./px-house-keeping.sh
```

With a specific Portworx namespace:

```bash
./px-house-keeping.sh portworx-cwdc
```

With audit logging:

```bash
LOG_DIR=./logs ./px-house-keeping.sh
```

---

## What the script does

1. **Scan** – Finds a Portworx pod, lists all PX volumes, and matches them to PVs (namespace, PVC, phase).
2. **Print table** – Shows every volume as **Bound**, **Released**, or **Orphaned (No PV)**.
3. **Summary** – Counts Total, Healthy (Bound), Released (ghost PVs), Orphaned.
4. **Phase 1** – If there are Released PVs, asks for confirmation and then deletes those PVs. Optionally rescans so new orphans appear for Phase 2.
5. **Phase 2** – If there are orphaned volumes, asks for confirmation and then runs `pxctl volume detach` and `pxctl volume delete --force` for each. **This is permanent and reclaims space.**

You can answer **n** to either phase and only run the part you want.

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_DIR` | (empty) | If set (e.g. `./logs`), appends the audit output to `px-housekeeping_YYYYMMDD.log`. |
| `TZ` | `Asia/Bangkok` | Timezone for log timestamps. |

---

## Retain vs Delete (reminder)

- **ReclaimPolicy: Delete** – Deleting the PVC leads to automatic deletion of the PV and the backend volume. Simple, but **one mistake and data is gone**.
- **ReclaimPolicy: Retain** – Deleting the PVC leaves the PV (and data) in place. You **must** run a housekeeping process (like this script) to reclaim space and clean references. **This script makes that process easier for Operations** while keeping the safety of Retain.

---

## Files

- **`px-house-keeping.sh`** – Main script (in this directory).
- **`./logs/px-housekeeping_YYYYMMDD.log`** – Optional audit log when `LOG_DIR` is set.

---

## License

Use at your own risk. Deleting Released PVs and orphaned volumes is irreversible. Ensure you have verified what is safe to delete before confirming.
