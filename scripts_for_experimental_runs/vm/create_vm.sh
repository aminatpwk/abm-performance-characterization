#!/usr/bin/env bash
# vm/create_vm.sh
# Provisions a fresh C4 VM for one error-margin measurement run.
# Outputs the VM name to stdout so the caller can capture it.
# Usage: VM_NAME=$(bash vm/create_vm.sh 01)

set -euo pipefail

# --- config -------------------------------------------------------------
RUN_ID="${1:?Usage: create_vm.sh <run_id> e.g. 01}"
PROJECT=$(gcloud config get-value project 2>/dev/null || true)
[[ -z "${PROJECT}" ]] && { echo "ERROR: No GCP project configured." >&2; exit 1; }
ZONE="europe-west1-b"
VM_NAME="biodynamo-run-${RUN_ID}"
MACHINE_TYPE="c4-standard-16"               # 16-core for the new runs
IMAGE_FAMILY="ubuntu-2204-lts"
IMAGE_PROJECT="ubuntu-os-cloud"
DISK_TYPE="hyperdisk-balanced"              # required for C4
DISK_SIZE_GB="50"
NETWORK="abm-net"
SUBNET="abm-subnet-euw1"                    # may need updating if zone changes

# --- verify zone -------------------------------------------------------
echo "[1/3] Verifying ${MACHINE_TYPE} is available in ${ZONE}..." >&2
ZONE_CHECK=$(gcloud compute machine-types list \
  --filter="zone=${ZONE} AND name=${MACHINE_TYPE}" \
  --format="value(zone)" 2>/dev/null | head -n1)

if [[ -z "${ZONE_CHECK:-}" ]]; then
  echo "ERROR: ${MACHINE_TYPE} not available in ${ZONE}." >&2
  exit 1
fi
echo "    zone: ${ZONE} ✓" >&2

# --- create VM ---------------------------------------------------------
# Idempotency: if a previous failed run left a VM with the same name behind,
# delete it first. CISPA's europe-west1 C4 quota is 24 vCPU — a single
# 16-vCPU orphan blocks the whole experiment.
EXISTING=$(gcloud compute instances describe "${VM_NAME}" \
  --zone="${ZONE}" --format="value(name)" 2>/dev/null || true)
if [[ -n "${EXISTING}" ]]; then
  echo "    WARNING: stale VM ${VM_NAME} from a previous run found; deleting it..." >&2
  gcloud compute instances delete "${VM_NAME}" --zone="${ZONE}" --quiet >&2
fi

echo "[2/3] Creating VM ${VM_NAME} (${MACHINE_TYPE}) in ${ZONE}..." >&2
# Redirect to stderr: prints "Created [URL]" + the NAME/STATUS table.
gcloud compute instances create "${VM_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --machine-type="${MACHINE_TYPE}" \
  --image-family="${IMAGE_FAMILY}" \
  --image-project="${IMAGE_PROJECT}" \
  --boot-disk-size="${DISK_SIZE_GB}GB" \
  --boot-disk-type="${DISK_TYPE}" \
  --boot-disk-device-name="${VM_NAME}" \
  --network="${NETWORK}" \
  --subnet="${SUBNET}" \
  --network-tier=PREMIUM \
  --stack-type=IPV4_ONLY \
  --shielded-vtpm \
  --shielded-integrity-monitoring \
  --no-shielded-secure-boot \
  --metadata=enable-oslogin=FALSE \
  --labels="purpose=biodynamo-error-margin,run-id=${RUN_ID}" \
  --maintenance-policy=MIGRATE \
  --performance-monitoring-unit=standard \
  --provisioning-model=STANDARD >&2

# --- wait for SSH ------------------------------------------------------
echo "[3/3] Waiting for SSH to become available..." >&2
SSH_ERR_LOG=$(mktemp)
for i in $(seq 1 30); do
  if gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --quiet \
       --command="echo ssh-ready" >/dev/null 2>"${SSH_ERR_LOG}"; then
    echo "    ready after ${i} attempt(s)" >&2
    rm -f "${SSH_ERR_LOG}"
    break
  fi
  sleep 5
  if [[ $i -eq 30 ]]; then
    echo "ERROR: SSH never became available. Last error:" >&2
    cat "${SSH_ERR_LOG}" >&2
    rm -f "${SSH_ERR_LOG}"
    exit 1
  fi
done

# --- log VM metadata ---------------------------------------------------
# Note: this writes to a LOCAL file (the orchestrator runs locally).
# We use a dedicated filename (vm_instance.json), NOT run.log, because
# pull_results.sh recursively scp's the remote results dir on top of this
# directory and would otherwise overwrite our metadata.
echo "[3/3] Logging VM metadata..." >&2
LOCAL_RUN_DIR="benchmark_results/error_margin_study/vm_run_${RUN_ID}"
mkdir -p "${LOCAL_RUN_DIR}"
INSTANCE_INFO=$(gcloud compute instances describe "${VM_NAME}" \
  --zone="${ZONE}" --format="json(name,machineType,zone,status,creationTimestamp,networkInterfaces)")
echo "${INSTANCE_INFO}" > "${LOCAL_RUN_DIR}/vm_instance.json"

echo "${VM_NAME}"