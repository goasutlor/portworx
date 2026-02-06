# px-volume-placement

**Author:** Sontas Jiamsripong

**Prerequisite: Run `oc login` to your OpenShift cluster before running this script.**

---

## Purpose

When Pods or StatefulSets are created with Portworx PVCs, replicas may be placed on storage nodes that are **not** on the same host as the Pod. Every read/write then crosses the network, causing **latency**. This script helps you:

1. **Scan** all namespaces for PVCs using a **selectable StorageClass** (not hardcoded).
2. **Analyze** placement: for each PVC, see whether volume replicas are on the same node as the Pod (LOCAL) or elsewhere (REMOTE).
3. **Organize** volumes so at least one replica is on the Pod’s host, reducing latency.
4. **Monitor** cluster state and pool balance before/after actions.

---

## Strategy (Rep=2)

For replication factor 2:

1. **Expand** to Rep=3 by adding a replica on the Pod’s node.
2. **Remove** a replica from a node that is **not** the Pod’s host.

Result: Rep=2 with at least one replica local to the Pod.

---

## Features

| Feature | Description |
|--------|-------------|
| **StorageClass selection** | Choose which SC to scan at runtime; reusable by others (not stuck to one SC). |
| **Wide scan** | All namespaces; shows PVC, Pod node, replica nodes, LOCAL/REMOTE/NO_POD. |
| **Cluster state** | PX storage nodes, capacity, used space. |
| **Pool balance** | Util spread (min–max); warns if manual placement skews balance. |
| **Organize** | Move replicas to Pod node (add → remove flow). |
| **Rescan** | Re-scan after organize to verify. |
| **Logging** | Actions logged to `./logs/px-volume-placement_YYYYMMDD.log`. |

---

## Balance concern

Portworx auto-balance distributes load across pools. **Manual placement** may concentrate data on fewer nodes and create imbalance. The script shows pool utilization spread and warns if it is high (e.g. >20%). Consider running a pool rebalance later if needed.

---

## Requirements

- **OpenShift** cluster with Portworx.
- **`oc`** logged in (`oc login` done before running).
- **`jq`** installed.

---

## Usage

```bash
# Ensure you are logged in
oc login <cluster-url>

chmod +x px-volume-placement.sh
./px-volume-placement.sh
```

### Menu

| Option | Description |
|--------|-------------|
| **[1] Rescan** | Scan PVCs for selected SC; show placement table, cluster state, balance. |
| **[2] Cluster state** | Show PX storage nodes and utilization. |
| **[3] Pool balance** | Show util spread and imbalance warning. |
| **[4] Select PVCs** | Toggle selection by ID (e.g. `1 3 5`) or `a` for all. |
| **[5] Organize selected** | For selected REMOTE PVCs, move replicas to Pod node. |
| **[6] Change StorageClass** | Pick a different SC for scan. |
| **[7] Increase Rep** | Add replica on specified node (e.g. fix Rep=1 → Rep=2). |
| **[8] Decrease Rep** | Remove replica from specified node. WARNING: Rep=1 = no HA. |
| **[q] Quit** | Exit. |

### Flow

1. Run script → select StorageClass.
2. **[1] Rescan** → review placement (LOCAL = good, REMOTE = high latency).
3. **[4] Select** the REMOTE PVCs you want to fix (e.g. `2 5 7` or `a`).
4. **[5] Organize** → script adds replica on Pod node, then removes from non-Pod node.
5. **[1] Rescan** again to confirm.

### Increase/Decrease Rep (fix Rep=1 or adjust manually)

- **[7] Increase Rep:** Select PVC(s), then for each: add replica on Pod node (default) or enter node IP. Use to fix volumes that accidentally dropped to Rep=1.
- **[8] Decrease Rep:** Select PVC(s), then for each: enter node IP to remove replica from. WARNING: Rep=1 = no HA; Pod may go down if that node fails.

---

## Environment variables

| Variable | Description |
|----------|-------------|
| `PX_SC` | Pre-select StorageClass (skip menu). Example: `PX_SC=px-app-rep2-dbremote ./px-volume-placement.sh` |
| `LOG_DIR` | Log directory (default: `./logs`). |

---

## Files

- **`px-volume-placement.sh`** – Main script.
- **`./logs/px-volume-placement_YYYYMMDD.log`** – Daily action log.

---

## License

Use at your own risk. Replica placement changes affect production volumes. Ensure you understand the impact before organizing.
