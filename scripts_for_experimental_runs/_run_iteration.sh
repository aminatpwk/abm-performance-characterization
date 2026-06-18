#!/usr/bin/env bash
# _run_iteration.sh
# Runs ONE end-to-end iteration of the error-margin experiment:
#   create VM -> upload scripts -> setup -> launch sim -> poll -> pull -> destroy
#
# Invoked by run_experiment.sh as a SEPARATE bash process. This is deliberate:
# the same logic embedded in `if ! ( subshell with set -e )` in the parent
# would silently swallow command failures because bash suppresses set -e
# inside compound commands that sit in `if`, `||`, `&&`, or `!` contexts.
# A standalone child shell starts fresh, so `set -euo pipefail` is fully
# in effect for every command here.
#
# Usage:
#   bash _run_iteration.sh <run_id>
# Env vars (set by parent):
#   SCRIPTS_DIR          absolute local path to scripts/
#   VM_NAME_FILE         path where this script writes the VM name on success
#   ZONE                 GCP zone
#   RESULTS_BASE         local results dir (relative)
#   POLL_INTERVAL        seconds between status polls
#   MAX_POLL_FAILURES    consecutive SSH failures tolerated
#   REMOTE_SCRIPTS_DIR   directory name under remote $HOME to upload scripts to

set -euo pipefail

RUN_ID="${1:?Usage: _run_iteration.sh <run_id>}"

: "${SCRIPTS_DIR:?must be set by parent}"
: "${VM_NAME_FILE:?must be set by parent}"
: "${ZONE:?must be set by parent}"
: "${RESULTS_BASE:?must be set by parent}"
: "${POLL_INTERVAL:?must be set by parent}"
: "${MAX_POLL_FAILURES:?must be set by parent}"
: "${REMOTE_SCRIPTS_DIR:?must be set by parent}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }

ssh_vm() {
  # ssh_vm <vm_name> <remote command string>
  local vm="$1"; shift
  gcloud compute ssh "${vm}" --zone="${ZONE}" --quiet --command="$*"
}

LOCAL_RUN_DIR="${RESULTS_BASE}/vm_run_${RUN_ID}"
mkdir -p "${LOCAL_RUN_DIR}"

# 1. create VM
log "[run ${RUN_ID}] Creating VM..."
VM_NAME=$(bash "${SCRIPTS_DIR}/vm/create_vm.sh" "${RUN_ID}")
# Defensive sanity check: VM name must match the cartopia-run-NN pattern.
# If it doesn't, something polluted stdout again — fail loudly.
if [[ ! "${VM_NAME}" =~ ^cartopia-run-[0-9]+$ ]]; then
  log "ERROR: create_vm.sh returned an unexpected value (stdout pollution?):"
  printf '%s\n' "${VM_NAME}" >&2
  exit 1
fi
echo "${VM_NAME}" > "${VM_NAME_FILE}"
log "[run ${RUN_ID}] VM ready: ${VM_NAME}"

# 2. upload scripts to the VM
log "[run ${RUN_ID}] Uploading scripts to VM..."
gcloud compute scp --recurse --zone="${ZONE}" --quiet \
  "${SCRIPTS_DIR}" "${VM_NAME}:~/${REMOTE_SCRIPTS_DIR}"
log "[run ${RUN_ID}] Scripts uploaded"

# 3. setup environment on VM
log "[run ${RUN_ID}] Running setup..."
ssh_vm "${VM_NAME}" "bash ${REMOTE_SCRIPTS_DIR}/setup/setup_env.sh"
log "[run ${RUN_ID}] Setup complete"

# 4. launch simulation (returns immediately; tmux session keeps running)
log "[run ${RUN_ID}] Launching simulation in tmux on VM..."
ssh_vm "${VM_NAME}" "bash ${REMOTE_SCRIPTS_DIR}/simulation/run_simulation.sh ${RUN_ID}"
log "[run ${RUN_ID}] Simulation launched. Polling every ${POLL_INTERVAL}s."
log "[run ${RUN_ID}] To watch live: gcloud compute ssh ${VM_NAME} --zone=${ZONE} -- tmux attach -t sim_run_${RUN_ID}"

# 5. poll for completion from the local side
REMOTE_RUN_DIR="benchmark_results/error_margin_study/vm_run_${RUN_ID}"
SIM_START=$(date +%s)
POLL_FAILURES=0

while true; do
  sleep "${POLL_INTERVAL}"

  STATUS_RAW=$(ssh_vm "${VM_NAME}" "
    set +e
    if [[ -f ${REMOTE_RUN_DIR}/.sim_failed ]]; then echo STATUS=FAILED; exit 0; fi
    if [[ -f ${REMOTE_RUN_DIR}/.sim_complete ]]; then echo STATUS=DONE; exit 0; fi
    echo STATUS=RUNNING
    REP=\$(cat ${REMOTE_RUN_DIR}/.current_rep 2>/dev/null || echo unknown)
    echo CURRENT_REP=\$REP
    echo ---TAIL---
    tail -n 3 ${REMOTE_RUN_DIR}/rep_\${REP}.stderr 2>/dev/null || true
  " 2>/dev/null) || STATUS_RAW=""

  if [[ -z "${STATUS_RAW}" ]]; then
    POLL_FAILURES=$((POLL_FAILURES + 1))
    log "[run ${RUN_ID}] poll failed (${POLL_FAILURES}/${MAX_POLL_FAILURES}) — VM unreachable, retrying"
    if [[ ${POLL_FAILURES} -ge ${MAX_POLL_FAILURES} ]]; then
      log "[run ${RUN_ID}] giving up after ${MAX_POLL_FAILURES} consecutive poll failures"
      exit 1
    fi
    continue
  fi
  POLL_FAILURES=0

  ELAPSED=$(( $(date +%s) - SIM_START ))
  H=$(( ELAPSED / 3600 )); M=$(( (ELAPSED % 3600) / 60 ))

  case "${STATUS_RAW}" in
    *STATUS=FAILED*)
      log "[run ${RUN_ID}] simulation FAILED after ${H}h ${M}m"
      exit 1
      ;;
    *STATUS=DONE*)
      log "[run ${RUN_ID}] simulation complete after ${H}h ${M}m"
      break
      ;;
    *STATUS=RUNNING*)
      CURRENT_REP=$(echo "${STATUS_RAW}" | grep '^CURRENT_REP=' | head -1 | cut -d= -f2)
      TAIL=$(echo "${STATUS_RAW}" | sed -n '/---TAIL---/,$ p' | tail -n 3 | tr '\n' ' | ')
      log "[run ${RUN_ID}] rep=${CURRENT_REP:-?} elapsed=${H}h${M}m | ${TAIL:-(no log yet)}"
      ;;
  esac
done

# 6. pull results
log "[run ${RUN_ID}] Pulling results..."
bash "${SCRIPTS_DIR}/transfer/pull_results.sh" "${VM_NAME}" "${RUN_ID}"
log "[run ${RUN_ID}] Results transferred"

# 7. destroy VM
log "[run ${RUN_ID}] Destroying VM..."
bash "${SCRIPTS_DIR}/vm/destroy_vm.sh" "${VM_NAME}" "${RUN_ID}"
log "[run ${RUN_ID}] VM destroyed"
