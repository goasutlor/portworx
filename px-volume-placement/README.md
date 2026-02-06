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

---

## Screen Example

```
=== px-volume-placement ===
[1] Rescan
[2] Cluster state
[3] Pool balance
[4] Select PVCs
[5] Organize selected (move replicas to Pod node)
[6] Change StorageClass
[7] Increase Rep (add replica on node)
[8] Decrease Rep (remove replica from node)
[b] Back (refresh view)
[q] Quit
Choice: b

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SC: px-repl2 | PX: portworx
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ID   SEL  NAMESPACE          PVC                        POD_NODE                 Rep   PLACEMENT REPLICAS
--------------------------------------------------------------------------------
-- Namespace: app-ns --
1    [ ]  app-ns             data-controlcenter-0       node-1.example.com       2     LOCAL    10.0.0.1 10.0.0.2
2    [ ]  app-ns             data-kafka-0               node-2.example.com       2     LOCAL    10.0.0.2 10.0.0.1
3    [ ]  app-ns             data-kafka-1               node-3.example.com       2     LOCAL    10.0.0.1 10.0.0.3
4    [x]  app-ns             data-kafka-2               node-1.example.com       2     LOCAL    10.0.0.1 10.0.0.2
5    [ ]  app-ns             data-storage-0             node-3.example.com       2     LOCAL    10.0.0.1 10.0.0.3
6    [ ]  app-ns             data-storage-1             node-1.example.com       2     LOCAL    10.0.0.2 10.0.0.1
7    [ ]  app-ns             data-storage-2             node-2.example.com       2     LOCAL    10.0.0.2 10.0.0.3
-- Namespace: prod-ns --
8    [ ]  prod-ns            data-sts-0                 node-1.example.com       2     LOCAL    10.0.0.1 10.0.0.2
-- Namespace: test-ns --
9    [ ]  test-ns            data-fio-0                 node-2.example.com       2     LOCAL    10.0.0.2 10.0.0.3
10   [ ]  test-ns            data-fio-1                 node-3.example.com       2     LOCAL    10.0.0.2 10.0.0.3
11   [ ]  test-ns            data-fio-2                 node-1.example.com       2     LOCAL    10.0.0.2 10.0.0.1
--------------------------------------------------------------------------------
```

### Table columns

| Column | Description |
|--------|-------------|
| **ID** | Row number for selection. |
| **SEL** | `[x]` = selected for Organize/Increase/Decrease Rep; `[ ]` = not selected. |
| **NAMESPACE** | Kubernetes namespace. |
| **PVC** | PersistentVolumeClaim name. |
| **POD_NODE** | Node where the Pod using this PVC is running. |
| **Rep** | Replication factor (number of replicas). |
| **PLACEMENT** | **LOCAL** (green) = at least one replica on Pod node; **REMOTE** (red) = all replicas on other nodes; **NO_POD** = no running Pod. |
| **REPLICAS** | Node IPs where volume replicas reside. |

---

## Menu Reference

| Option | How it works |
|--------|--------------|
| **[1] Rescan** | Re-scans all namespaces for PVCs using the current StorageClass. Fetches replica placement from Portworx and refreshes the table. Use after Organize or Rep changes to see updated results. |
| **[2] Cluster state** | Shows `pxctl cluster list` output: Node ID, DATA IP, CPU, MEM, STATUS. Lets you verify which storage nodes are online. |
| **[3] Pool balance** | Shows `pxctl status` output: pool capacity, used space per node. Manual placement may skew utilization; check after Organize or Rep changes. |
| **[4] Select PVCs** | Toggle selection for Organize [5], Increase Rep [7], Decrease Rep [8]. Enter IDs (e.g. `1 3 5`), `a` for all, or `b` to cancel. Shows feedback: ✓ Selected / ○ Deselected. |
| **[5] Organize selected** | For each **selected REMOTE** PVC: adds a replica on the Pod node (Rep+1), waits for sync, then removes a replica from a non-Pod node. Result: Rep unchanged, at least one replica local. Skips LOCAL and NO_POD. |
| **[6] Change StorageClass** | Prompts to pick a different StorageClass. Rescans PVCs for the new SC. Use `0` to cancel and keep current. |
| **[7] Increase Rep** | For each selected PVC: add a replica on a chosen node (default: Pod node if available). Use to fix Rep=1 → Rep=2. Portworx allows 1 replica per node. |
| **[8] Decrease Rep** | For each selected PVC: remove a replica from a chosen node (enter IP). Warning: Rep=1 = no HA; high risk if node fails. |
| **[b] Back** | Re-displays the PVC table. Use when screen scrolls or to refresh the view. |
| **[q] Quit** | Exits the script. |

### Typical flow

1. Run script → select StorageClass (or set `PX_SC` env).
2. Review the table: **LOCAL** = good, **REMOTE** = high latency (fix with Organize).
3. **[4] Select** the REMOTE PVCs to fix (e.g. `2 5 7` or `a` for all).
4. **[5] Organize** → script adds replica on Pod node, then removes from non-Pod node. Auto-rescans after.
5. Use **[b]** to refresh the table, or **[1] Rescan** to re-scan manually.

### Increase/Decrease Rep

- **Rep=1** volumes have no HA; use **[7] Increase Rep** to add a second replica on another node.
- **[8] Decrease Rep** removes a replica; confirm carefully—Rep=1 means the Pod will fail if that node goes down.

---

## Environment variables

| Variable | Description |
|----------|-------------|
| `PX_SC` | Pre-select StorageClass (skip menu). Example: `PX_SC=px-repl2 ./px-volume-placement.sh` |
| `LOG_DIR` | Log directory (default: `./logs`). |

---

## Files

- **`px-volume-placement.sh`** – Main script.
- **`./logs/px-volume-placement_YYYYMMDD.log`** – Daily action log.

---

## License

Use at your own risk. Replica placement changes affect production volumes. Ensure you understand the impact before organizing.
