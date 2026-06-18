#!/usr/bin/env bash
# vm/destroy_vm.sh
# Destroys a VM instance only after confirming the results transfer succeeded.
# Usage: bash vm/destroy_vm.sh <vm_name> <run_id>

set -euo pipefail

# --- args ---------------------------------------------------------------
VM_NAME="${1:?Usage: destroy_vm.sh <vm_name> <run_id>}"
RUN_ID="${2:?Usage: destroy_vm.sh <vm_name> <run_id>}"

# --- config -------------------------------------------------------------
PROJECT=$(gcloud config get-value project 2>/dev/null || true)
[[ -z "${PROJECT}" ]] && { echo "ERROR: No GCP project configured." >&2; exit 1; }
ZONE="europe-west1-b"
RESULTS_DIR="benchmark_results/error_margin_study/vm_run_${RUN_ID}"

# --- verify transfer completed ------------------------------------------
echo "[1/3] Verifying results transfer for run ${RUN_ID}..." >&2

# gate 1: directory must exist locally
if [[ ! -d "${RESULTS_DIR}" ]]; then
  echo "ERROR: results directory ${RESULTS_DIR} not found locally." >&2
  echo "       Transfer may not have completed. Aborting VM destruction." >&2
  exit 1
fi

# gate 2: both perf split files must be present
MISSING=()
for REP in 01 02; do
  if [[ ! -f "${RESULTS_DIR}/perf_splits/rep_${REP}.perf" ]]; then
    MISSING+=("rep_${REP}.perf")
  fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: missing perf files: ${MISSING[*]}" >&2
  echo "       Aborting VM destruction." >&2
  exit 1
fi

# gate 3: run.log must be present
if [[ ! -f "${RESULTS_DIR}/run.log" ]]; then
  echo "ERROR: run.log not found in ${RESULTS_DIR}." >&2
  echo "       Aborting VM destruction." >&2
  exit 1
fi

# gate 4: perf files must be non-empty
for REP in 01 02; do
  PERF_FILE="${RESULTS_DIR}/perf_splits/rep_${REP}.perf"
  if [[ ! -s "${PERF_FILE}" ]]; then
    echo "ERROR: ${PERF_FILE} is empty." >&2
    echo "       Aborting VM destruction." >&2
    exit 1
  fi
done

echo "    all transfer gates passed ✓" >&2

# --- confirm VM still exists -------------------------------------------
echo "[2/3] Confirming VM ${VM_NAME} exists in ${ZONE}..." >&2
VM_STATUS=$(gcloud compute instances describe "${VM_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

if [[ "${VM_STATUS}" == "NOT_FOUND" ]]; then
  echo "    VM ${VM_NAME} not found — already destroyed or never created." >&2
  echo "    Nothing to delete. Exiting cleanly." >&2
  exit 0
fi

echo "    VM found, status: ${VM_STATUS} ✓" >&2

# --- destroy VM --------------------------------------------------------
echo "[3/3] Destroying VM ${VM_NAME}..." >&2
gcloud compute instances delete "${VM_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --quiet

# --- verify deletion ---------------------------------------------------
VM_CHECK=$(gcloud compute instances describe "${VM_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

if [[ "${VM_CHECK}" != "NOT_FOUND" ]]; then
  echo "ERROR: VM ${VM_NAME} still exists after deletion attempt." >&2
  exit 1
fi

# --- log destruction timestamp -----------------------------------------
echo "vm_destroyed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${RESULTS_DIR}/run.log"
echo "vm_name=${VM_NAME}" >> "${RESULTS_DIR}/run.log"

echo "" >&2
echo "✓ VM '${VM_NAME}' destroyed. Run ${RUN_ID} complete." >&2
echo "  Results at: ${RESULTS_DIR}" >&2