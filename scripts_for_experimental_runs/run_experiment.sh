#!/usr/bin/env bash
# Master orchestrator for the error margin measurement study.
#
# Revised flow (fire-and-forget):
#   1. Create VM
#   2. Upload setup + simulation scripts only
#   3. Run setup (blocking, over SSH)
#   4. Launch simulation in a detached screen/nohup session (non-blocking)
#   5. Exit — the VM will rsync results back when the simulation finishes
#
# The VM calls home by running:
#   rsync -az <results_dir>/ <LOCAL_USER>@<LOCAL_HOST>:<LOCAL_RESULTS_DIR>/vm_run_<ID>/
# using a private key baked in at setup time (see CALLBACK_KEY_PATH below).
#
# Destroy VMs manually once you see results land locally.
#
# Usage:
#   bash run_experiment.sh
#
# Tip: run inside tmux so the setup phase (which IS blocking) survives a
# closed laptop:
#   tmux new -s biodynamo 'bash run_experiment.sh 2>&1 | tee experiment.out'

set -euo pipefail

# ── config ──────────────────────────────────────────────────────────────────

TOTAL_RUNS=1
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZONE="europe-west1-b"
RESULTS_BASE="benchmark_results/error_margin_study/iterations/results"

# Scripts uploaded to the VM (paths relative to SCRIPTS_DIR).
# Only what the VM actually needs — no analysis/transfer/orchestration scripts.
REMOTE_SCRIPTS=(
  "setup/setup_env.sh"
  "simulation/run_simulation.sh"
)
REMOTE_SCRIPTS_DIR="scripts"   # destination on the VM, relative to $HOME

# ── callback / push-home config ─────────────────────────────────────────────
# The VM will SSH back to this machine using CALLBACK_KEY_PATH as its identity.
# Set these to match your local environment.

LOCAL_HOST="${BIODYNAMO_LOCAL_HOST:-}"          # e.g. "192.168.1.42"  or a public IP/hostname
LOCAL_USER="${BIODYNAMO_LOCAL_USER:-${USER}}"   # user on the local machine the VM SSHes into
LOCAL_RESULTS_DIR="${BIODYNAMO_LOCAL_RESULTS_DIR:-${PWD}/${RESULTS_BASE}}"

# Path to the PRIVATE key on the *local* machine that will be copied onto the VM.
# The corresponding public key must already be in your local ~/.ssh/authorized_keys.
CALLBACK_KEY_PATH="${BIODYNAMO_CALLBACK_KEY_PATH:-${HOME}/.ssh/biodynamo_vm_callback}"

# ── helpers ──────────────────────────────────────────────────────────────────

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ── preflight checks ─────────────────────────────────────────────────────────

log "Checking required tools..."
for CMD in gcloud rsync ssh; do
  command -v "${CMD}" &>/dev/null || die "${CMD} not found locally. Please install it."
done
log "    all tools present"

PROJECT=$(gcloud config get-value project 2>/dev/null || true)
[[ -z "${PROJECT}" ]] && die "No GCP project configured. Run: gcloud config set project <project-id>"
log "    GCP project: ${PROJECT}"

[[ -z "${LOCAL_HOST}" ]] && die \
  "LOCAL_HOST is not set. Export BIODYNAMO_LOCAL_HOST=<your-machine-ip> before running."

[[ -f "${CALLBACK_KEY_PATH}" ]] || die \
  "Callback private key not found at ${CALLBACK_KEY_PATH}. \
See CALLBACK_KEY_PATH in this script."

[[ -f "${CALLBACK_KEY_PATH}.pub" ]] || die \
  "Public key ${CALLBACK_KEY_PATH}.pub not found. \
Make sure the keypair exists and the public key is in ~/.ssh/authorized_keys."

for SCRIPT in "${REMOTE_SCRIPTS[@]}" vm/create_vm.sh; do
  [[ -e "${SCRIPTS_DIR}/${SCRIPT}" ]] || die "${SCRIPT} not found under ${SCRIPTS_DIR}."
done
log "    all required scripts present"

mkdir -p "${RESULTS_BASE}"

# ── experiment log ───────────────────────────────────────────────────────────

EXPERIMENT_LOG="${RESULTS_BASE}/experiment.log"
{
  echo "experiment_started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "total_runs=${TOTAL_RUNS}"
  echo "gcp_project=${PROJECT}"
  echo "zone=${ZONE}"
  echo "local_host=${LOCAL_HOST}"
  echo "local_user=${LOCAL_USER}"
  echo "callback_key=${CALLBACK_KEY_PATH}"
} > "${EXPERIMENT_LOG}"

# ── main loop ────────────────────────────────────────────────────────────────

FAILED_RUNS=()

for i in 3; do
  RUN_ID=$(printf "%02d" "${i}")
  log "════════════════════════════════════════"
  log "Starting VM run ${RUN_ID} of ${TOTAL_RUNS}"
  log "════════════════════════════════════════"

  RUN_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  LOCAL_RUN_DIR="${RESULTS_BASE}/vm_run_${RUN_ID}"
  mkdir -p "${LOCAL_RUN_DIR}"

  rc=0

  # ── 1. create vm ──────────────────────────────────────────────────────────
  log "[run ${RUN_ID}] Creating VM..."
  VM_NAME=""
  VM_NAME=$(bash "${SCRIPTS_DIR}/vm/create_vm.sh" "${RUN_ID}" "${ZONE}") || rc=$?
  if [[ $rc -ne 0 || -z "${VM_NAME}" ]]; then
    log "ERROR: [run ${RUN_ID}] VM creation failed."
    FAILED_RUNS+=("${RUN_ID}")
    { echo "run_${RUN_ID}_status=FAILED_create_vm"
      echo "run_${RUN_ID}_started_at=${RUN_START}"; } >> "${EXPERIMENT_LOG}"
    continue
  fi

  # Validate name before storing it anywhere.
  [[ "${VM_NAME}" =~ ^biodynamo-run-[0-9]+$ ]] || die \
    "create_vm.sh returned unexpected VM name: '${VM_NAME}'"

  log "[run ${RUN_ID}] VM name: ${VM_NAME}"

  # Record VM name so you can destroy it manually later.
  echo "${VM_NAME}" > "${LOCAL_RUN_DIR}/.vm_name"

  # ── 2. upload scripts ─────────────────────────────────────────────────────
  log "[run ${RUN_ID}] Uploading scripts to VM..."
  for SCRIPT in "${REMOTE_SCRIPTS[@]}"; do
    REMOTE_SUBDIR="${REMOTE_SCRIPTS_DIR}/$(dirname "${SCRIPT}")"
    gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" \
      --command="mkdir -p '${REMOTE_SUBDIR}'" || { rc=1; break; }
    gcloud compute scp \
      "${SCRIPTS_DIR}/${SCRIPT}" \
      "${VM_NAME}:${REMOTE_SUBDIR}/" \
      --zone="${ZONE}" || { rc=1; break; }
  done

  # Also upload the callback private key so the VM can push results home.
  gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" \
    --command="mkdir -p ~/.ssh && chmod 700 ~/.ssh" || rc=1
  gcloud compute scp \
    "${CALLBACK_KEY_PATH}" \
    "${VM_NAME}:~/.ssh/biodynamo_callback_key" \
    --zone="${ZONE}" || rc=1
  gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" \
    --command="chmod 600 ~/.ssh/biodynamo_callback_key" || rc=1

  if [[ $rc -ne 0 ]]; then
    log "ERROR: [run ${RUN_ID}] Script upload failed."
    FAILED_RUNS+=("${RUN_ID}")
    { echo "run_${RUN_ID}_status=FAILED_upload"
      echo "run_${RUN_ID}_started_at=${RUN_START}"; } >> "${EXPERIMENT_LOG}"
    continue
  fi

  # ── 3. run setup (blocking) ───────────────────────────────────────────────
  log "[run ${RUN_ID}] Running setup on VM (blocking)..."
  gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" \
    --command="bash '${REMOTE_SCRIPTS_DIR}/setup/setup_env.sh'" || rc=$?

  if [[ $rc -ne 0 ]]; then
    log "ERROR: [run ${RUN_ID}] Setup failed."
    FAILED_RUNS+=("${RUN_ID}")
    { echo "run_${RUN_ID}_status=FAILED_setup"
      echo "run_${RUN_ID}_started_at=${RUN_START}"; } >> "${EXPERIMENT_LOG}"
    continue
  fi

  # ── 4. launch simulation (non-blocking, VM pushes results when done) ───────
  #
  # The remote wrapper script does three things:
  #   a) runs the simulation
  #   b) rsyncs the results directory back to the local machine
  #   c) writes a DONE sentinel in the results dir (visible once rsync lands)
  #
  # Everything runs under nohup so it survives the SSH session closing.

  REMOTE_RESULTS_DIR="results/vm_run_${RUN_ID}"
  RSYNC_DEST="${LOCAL_USER}@${LOCAL_HOST}:${LOCAL_RESULTS_DIR}/vm_run_${RUN_ID}/"

  # Build the remote one-liner inline; no extra script file needed.
  REMOTE_CMD=$(cat <<REMOTECMD
set -euo pipefail
mkdir -p "\${HOME}/${REMOTE_RESULTS_DIR}"

# Run simulation, capturing output.
bash "\${HOME}/${REMOTE_SCRIPTS_DIR}/simulation/run_simulation.sh" \
  "${RUN_ID}" "\${HOME}/${REMOTE_RESULTS_DIR}" \
  > "\${HOME}/${REMOTE_RESULTS_DIR}/simulation.log" 2>&1
SIM_RC=\$?

# Record exit status alongside results.
echo "simulation_exit_code=\${SIM_RC}" >> "\${HOME}/${REMOTE_RESULTS_DIR}/run_meta.txt"
echo "run_id=${RUN_ID}"               >> "\${HOME}/${REMOTE_RESULTS_DIR}/run_meta.txt"
echo "vm_name=${VM_NAME}"             >> "\${HOME}/${REMOTE_RESULTS_DIR}/run_meta.txt"
echo "finished_at=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "\${HOME}/${REMOTE_RESULTS_DIR}/run_meta.txt"

# Push results home. StrictHostKeyChecking=no because the VM has never seen
# your local host before; AcceptNewHostKey is fine here — traffic is LAN/VPN.
rsync -az --progress \
  -e "ssh -i \${HOME}/.ssh/biodynamo_callback_key \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null" \
  "\${HOME}/${REMOTE_RESULTS_DIR}/" \
  "${RSYNC_DEST}"
REMOTECMD
)

  log "[run ${RUN_ID}] Launching simulation in background (fire-and-forget)..."
  gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" \
    --command="nohup bash -c $(printf '%q' "${REMOTE_CMD}") \
               > \"\${HOME}/nohup_run_${RUN_ID}.log\" 2>&1 </dev/null &
               echo \"Simulation PID: \$!\"" || rc=$?

  if [[ $rc -ne 0 ]]; then
    log "ERROR: [run ${RUN_ID}] Failed to launch simulation."
    FAILED_RUNS+=("${RUN_ID}")
    { echo "run_${RUN_ID}_status=FAILED_launch"
      echo "run_${RUN_ID}_started_at=${RUN_START}"; } >> "${EXPERIMENT_LOG}"
    continue
  fi

  RUN_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    echo "run_${RUN_ID}_status=LAUNCHED"
    echo "run_${RUN_ID}_vm=${VM_NAME}"
    echo "run_${RUN_ID}_started_at=${RUN_START}"
    echo "run_${RUN_ID}_launched_at=${RUN_END}"
    echo "run_${RUN_ID}_results_dest=${LOCAL_RUN_DIR}"
  } >> "${EXPERIMENT_LOG}"

  log "[run ${RUN_ID}] Simulation launched. Results will arrive at: ${LOCAL_RUN_DIR}/"
  log "[run ${RUN_ID}] VM ${VM_NAME} is running unattended — destroy manually when results land."
done

# ── summary ──────────────────────────────────────────────────────────────────

log "════════════════════════════════════════"
log "All VMs launched."
log "════════════════════════════════════════"

LAUNCHED_RUNS=$(( TOTAL_RUNS - ${#FAILED_RUNS[@]} ))
{
  echo "experiment_finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "launched_runs=${LAUNCHED_RUNS}"
  echo "failed_runs=${FAILED_RUNS[*]:-none}"
} >> "${EXPERIMENT_LOG}"

log "Launched : ${LAUNCHED_RUNS}/${TOTAL_RUNS}"
if [[ ${#FAILED_RUNS[@]} -gt 0 ]]; then
  log "Failed (pre-launch): ${FAILED_RUNS[*]}"
fi

log ""
log "Next steps:"
log "  • Watch for results in: ${RESULTS_BASE}/vm_run_*/run_meta.txt"
log "  • Each file appears only after the VM has rsynced results home."
log "  • Once all results are in, run:"
log "      python3 ${SCRIPTS_DIR}/analyze/compute_error_margin.py \\"
log "              --runs-dir ${RESULTS_BASE}"
log "  • Then destroy VMs manually:"
log "      gcloud compute instances list"
log "      gcloud compute instances delete <vm-name> --zone=${ZONE}"
log ""
log "Experiment log: ${EXPERIMENT_LOG}"