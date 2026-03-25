# hpcs-kp-migrate

Migration toolkit for moving OpenShift Data Foundation (ODF) encryption keys from IBM Hyper Protect Crypto Services (HPCS) to IBM Key Protect (KP).

ODF uses a KMS to manage encryption keys for Ceph OSDs, CSI-provisioned RBD volumes, and NooBaa. When switching from HPCS to Key Protect, the encryption keys must be migrated without data loss or downtime. This project provides three bash scripts — one for each subsystem — that handle the full migration lifecycle: inventory, export, import, verification, switchover, and rollback.

## Scripts

### `migrate-osd.sh` — OSD encryption keys

Migrates the per-OSD Standard Keys that Rook stores in the KMS (one per encrypted PVC, identified by alias). Exports key payloads from HPCS and imports them into Key Protect with the same name, alias, and payload. Then updates the Kubernetes secret and KMS ConfigMap so Rook uses the new KP instance, triggering a rolling OSD restart.

**Phases:** `check` → `phase1` (inventory) → `phase2` (export) → `phase3` (import) → `phase4` (verify) → `phase5` (switch) → `phase6` (verify recovery)

### `migrate-csi.sh` — CSI-encrypted RBD volumes

Migrates per-volume Data Encryption Keys (DEKs) for RBD volumes using CSI-level encryption. Each volume's DEK is stored as wrapped (envelope-encrypted) metadata on the RBD image. The script unwraps DEKs using the HPCS root key, re-wraps them with the KP root key, updates the RBD image metadata, and switches the CSI KMS ConfigMap to point at Key Protect.

**Phases:** `check` → `pre` (scale down CSI provisioners) → `phase1` (discover volumes) → `phase2` (unwrap via HPCS) → `phase3` (wrap via KP) → `phase4` (update RBD metadata) → `phase5` (update CSI KMS config) → `post` (restore CSI provisioners)

### `migrate-noobaa.sh` — NooBaa root master key

Migrates the single NooBaa root master key (`rootkeyb64-<noobaa-uid>`). Exports the Standard Key from HPCS, imports it into Key Protect, then updates the token secret and restarts the NooBaa operator. Requires `migrate-osd.sh phase5` to have already switched the shared KMS ConfigMap.

**Phases:** `check` → `phase1` (inventory) → `phase2` (export) → `phase3` (import) → `phase4` (verify) → `phase5` (switch) → `phase6` (verify recovery)

### `common.sh` — Shared helpers

Logging, Kubernetes helpers, IAM token management, `.env` loading. Sourced by all migration scripts.

## Recommended migration order

1. **CSI volumes** — `migrate-csi.sh` pre → phases 1–5 → post (independent KMS ConfigMap entry)
2. **OSD keys** — `migrate-osd.sh` phases 1–6 (switches the shared KMS ConfigMap)
3. **NooBaa key** — `migrate-noobaa.sh` phases 1–6 (depends on the KMS ConfigMap already pointing to KP)

Each script supports `rollback` and `cleanup` commands.

## Prerequisites

- `oc` or `kubectl` with access to the ODF cluster
- `jq` and `curl`
- Ceph toolbox pod enabled (`storagecluster.spec.enableCephTools: true`)
- API keys for both the source HPCS instance and the destination Key Protect instance

## Configuration

Copy `.env.example` to `.env` and fill in the KMS credentials:

```sh
cp .env.example .env
# Edit .env with your HPCS and Key Protect credentials
```

All settings can also be passed as environment variables. Many HPCS settings (instance ID, URL, API key) are auto-detected from the live cluster's CephCluster/NooBaa CRs and token secrets.

See each script's `--help` output (run without arguments) for the full list of environment variables.
