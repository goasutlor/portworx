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

## Example output

(Look and feel only; namespaces, IPs, and volume IDs below are generic.)

```
Portworx namespace: portworx
Scanning Portworx Volumes...
-----------------------------------------------------------------------------------------------------------------------------------------------
Namespace          | Volume ID / PV Name                           | PVC Name                         | PX Status    | PV Phase
-----------------------------------------------------------------------------------------------------------------------------------------------
> NAMESPACE: app-preprod
  -                | pvc-124df4fd-51eb-4cf5-9fcb-9b47c1adf9e4      | prometheus-data-controlcenter-0  | (192.168.1.10) | Bound
  -                | pvc-4b28aeaf-7515-4cf4-8c0e-ff694d0c02ca      | data0-kraft-0                    | (192.168.1.12) | Bound
  -                | pvc-7604d127-0931-40d9-aef7-e8c6f1f3857b      | data0-controlcenter-0            | (192.168.1.10) | Bound
  -                | pvc-8f9dc89d-3913-4ab5-8967-7a9e2cefb2ca      | data0-kafka-1                    | (192.168.1.12) | Bound
  -                | pvc-9485a1d4-690b-43df-b609-6dd73b8bf3aa      | data0-kafka-0                    | (192.168.1.11) | Bound
  -                | pvc-9eb80608-c7b5-452a-a064-f6069a76ff91      | data0-kafka-2                    | (192.168.1.10) | Bound
  -                | pvc-c68e24c4-dda2-4085-b1a0-eb770a3df4b4      | data0-kraft-1                    | (192.168.1.10) | Bound
  -                | pvc-eceba169-7464-4426-8f5c-06399af79b4a      | data0-kraft-2                    | (192.168.1.11) | Bound
> NAMESPACE: app-prod
  -                | pvc-7d3dc52f-0da9-4df1-9e72-608f72dd3721      | data-fio-sts-401-0               | (192.168.1.10) | Bound
> NAMESPACE: openshift-monitoring
  -                | pvc-35cb2c39-d79a-4af0-8363-172876731c85      | prometheus-k8s-db-prometheus-k8s-0 | (192.168.1.11) | Bound
  -                | pvc-3a6ac494-8822-4603-939d-d3a89c4c0b30      | prometheus-k8s-db-prometheus-k8s-1 | (192.168.1.10) | Bound
  -                | pvc-4e2b59b7-e82b-4051-a8fc-9c9d2b83b099      | alertmanager-main-db-alertmanager-main-1 | (192.168.1.10) | Bound
  -                | pvc-f31475c4-0401-4246-8eb6-93f69e1c8b30      | alertmanager-main-db-alertmanager-main-0 | (192.168.1.11) | Bound
> NAMESPACE: perf-test
  -                | pvc-1d185c69-8f56-474e-9ac7-94bd15d2aeae      | data-fio-sts-403-0               | (192.168.1.12) | Bound
  -                | pvc-504790ce-ea5f-4cf4-a5f2-00916cc84403      | data-fio-sts-2-0                 | (192.168.1.11) | Bound
  -                | pvc-b7f3085f-5a5b-4af9-babf-c06f722abb5c      | data-fio-sts-2-1                 | (192.168.1.12) | Bound
  -                | pvc-c7ff20e3-0983-4f6f-8813-ca529ba34de5      | data-fio-sts-2-2                 | (192.168.1.10) | Bound
  -                | pvc-cf06566c-7058-485e-8f0f-aa200733d2b4      | data-fio-sts-402-0               | (192.168.1.11) | Bound
  -                | pvc-e83d5ba9-7246-49a4-80f2-c1735fdd685b      | data-fio-sts-401-0               | (192.168.1.10) | Bound
-----------------------------------------------------------------------------------------------------------------------------------------------
AUDIT SUMMARY:
Total Volumes: 19 | Healthy (Bound): 19 | Released (Ghost): 0 | Orphaned (No PV): 0

No Orphaned Volumes found for deletion.
Housekeeping Process Finished.
[ops@host ~]$
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
