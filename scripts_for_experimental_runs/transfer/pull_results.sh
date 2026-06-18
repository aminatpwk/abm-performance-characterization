#!/usr/bin/env bash
# transfer/pull_results.sh
# Pulls results from the remote VM to the local results directory.
# Must succeed before destroy_vm.sh is allowed to run.
# Usage: bash transfer/pull_results.sh <vm_name> <run_id>

set -euo pipefail

# --- args & config -----------------------------------------------------
VM_NAME="${1:?Usage: pull_results.sh <vm_name> <run_id>}"
RUN_ID="${2:?Usage: pull_results.sh <vm_name> <run_id>}"

ZONE="europe-west1-b"
# Relative paths on the remote side — gcloud compute scp resolves them
# against the OS Login user's $HOME on the VM, which is NOT the same as the
# local $HOME (the OS Login user is e.g. agirayyaglikci_gmail_com).
REMOTE_RESULTS="benchmark_results/error_margin_study/vm_run_${RUN_ID}"
LOCAL_RESULTS="benchmark_results/error_margin_study/vm_run_${RUN_ID}"

# --- prepare local directory -------------------------------------------
# Note: vm_instance.json from create_vm.sh already lives here. Do NOT delete.
mkdir -p "${LOCAL_RESULTS}"

# --- transfer ----------------------------------------------------------
# We use tar-over-ssh (NOT gcloud compute scp --recurse) because:
#   1. gcloud scp's directory-merge semantics differ between scp and the
#      sftp-based backend modern OpenSSH uses, and behave differently when
#      the local target dir already exists.
#   2. The local target dir already contains vm_instance.json from
#      create_vm.sh, so we must merge, not nest.
# `tar -x` always merges into an existing directory without nesting.
echo "[1/3] Pulling results from ${VM_NAME}..." >&2

gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --quiet \
  --command="tar -cf - -C benchmark_results/error_margin_study vm_run_${RUN_ID}" \
  | tar -xf - -C "benchmark_results/error_margin_study/"

echo "    transfer complete" >&2

# --- success gates -----------------------------------------------------
echo "[2/3] Verifying transferred files..." >&2

# gate 1: perf split files present and non-empty
MISSING=()
for REP in 01 02; do
  PERF_FILE="${LOCAL_RESULTS}/perf_splits/rep_${REP}.perf"
  if [[ ! -f "${PERF_FILE}" ]]; then
    MISSING+=("rep_${REP}.perf missing")
  elif [[ ! -s "${PERF_FILE}" ]]; then
    MISSING+=("rep_${REP}.perf empty")
  fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: perf file issues: ${MISSING[*]}" >&2
  exit 1
fi
echo "    perf_splits: rep_01.perf and rep_02.perf present and non-empty" >&2

# gate 2: run.log must be present
if [[ ! -f "${LOCAL_RESULTS}/run.log" ]]; then
  echo "ERROR: run.log not found after transfer." >&2
  exit 1
fi
echo "    run.log present" >&2

# gate 3: sim.log must be present (confirms inner script ran)
if [[ ! -f "${LOCAL_RESULTS}/sim.log" ]]; then
  echo "ERROR: sim.log not found. Simulation may not have completed." >&2
  exit 1
fi
echo "    sim.log present" >&2

# gate 4: completion marker must be present
if [[ ! -f "${LOCAL_RESULTS}/.sim_complete" ]]; then
  echo "ERROR: .sim_complete marker not found." >&2
  echo "       Simulation may still be running or failed." >&2
  exit 1
fi
echo "    .sim_complete marker present" >&2

# gate 5: setup_env.log from the VM user's home directory.
# Relative path — gcloud scp resolves against the remote user's $HOME,
# not the local user's.
gcloud compute scp \
  --zone="${ZONE}" \
  --quiet \
  "${VM_NAME}:setup_env.log" \
  "${LOCAL_RESULTS}/setup_env.log" \
  2>/dev/null || echo "WARNING: setup_env.log not found on VM, skipping." >&2

# --- log transfer timestamp --------------------------------------------
echo "[3/3] Logging transfer..." >&2
echo "transfer_completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${LOCAL_RESULTS}/run.log"

echo "" >&2
echo "pull_results.sh complete. Local results at: ${LOCAL_RESULTS}" >&2
ls -lh "${LOCAL_RESULTS}/perf_splits/" >&2