#!/usr/bin/env bash
# simulation/run_simulation.sh
# Runs on the remote VM. Generates an inner script that runs 4 reps of the
# epidemiology simulation under perf, launches it inside tmux, then returns
# IMMEDIATELY. The orchestrator on the local side polls for completion via
# short SSH calls — this way an SSH drop during the 36h+ runtime does not
# kill the experiment.
# Usage (on the VM):
#   bash simulation/run_simulation.sh <run_id>

set -euo pipefail

# --- args & config -----------------------------------------------------
RUN_ID="${1:?Usage: run_simulation.sh <run_id>}"
RESULTS_DIR="${HOME}/benchmark_results/error_margin_study/vm_run_${RUN_ID}"
PERF_DIR="${RESULTS_DIR}/perf_splits"
# Binary is built from the fork's epidemiology demo (setup_env.sh does this).
# Config is the user's measles.json (same fork). The upstream BioDynaMo runtime
# is installed at ~/biodynamo-vX.Y.Z/ — discovered dynamically below.
BINARY="${HOME}/biodynamo-fork/demo/epidemiology/build/epidemiology"
CONFIG="${HOME}/biodynamo-fork/demo/epidemiology/measles.json"
CORES=16
TMUX_SESSION="sim_run_${RUN_ID}"

# Discover the versioned BioDynaMo install directory (same logic as setup_env.sh).
shopt -s nullglob
BDM_CANDIDATES=("${HOME}"/biodynamo-v*/)
shopt -u nullglob
if [[ ${#BDM_CANDIDATES[@]} -eq 0 ]]; then
  echo "ERROR: No installed BioDynaMo found at ~/biodynamo-v*/" >&2
  exit 1
fi
BDM_DIR=$(printf '%s\n' "${BDM_CANDIDATES[@]}" | sort -V | tail -1)
BDM_DIR="${BDM_DIR%/}"

# Belt-and-suspenders: force visualization off via --inline-config even if
# measles.json already disables it. Adjust if BioDynaMo's Param schema changes.
INLINE_CONFIG='{"bdm::Param": {"export_visualization": false, "insitu_visualization": false, "live_visualization": false}}'

PERF_EVENTS="instructions,cycles,\
L2_RQSTS.MISS,\
L2_RQSTS.REFERENCES,\
MEM_LOAD_COMPLETED.L1_MISS_ANY,\
MEM_LOAD_RETIRED.L1_HIT,\
MEM_LOAD_RETIRED.L2_HIT,\
MEM_LOAD_RETIRED.L1_MISS,\
MEM_LOAD_RETIRED.L2_MISS,\
TOPDOWN.SLOTS_P,\
TOPDOWN.MEMORY_BOUND_SLOTS,\
MEMORY_ACTIVITY.STALLS_L1D_MISS,\
MEMORY_ACTIVITY.STALLS_L2_MISS"

# --- sanity checks -----------------------------------------------------
if [[ ! -x "${BINARY}" ]]; then
  echo "ERROR: binary not found at ${BINARY}. Was setup_env.sh run?" >&2
  exit 1
fi
if [[ ! -f "${CONFIG}" ]]; then
  echo "ERROR: config not found at ${CONFIG}." >&2
  exit 1
fi
if ! command -v tmux &>/dev/null; then
  echo "ERROR: tmux not found. Install with: sudo apt-get install -y tmux" >&2
  exit 1
fi

mkdir -p "${PERF_DIR}"

# --- write the inner simulation script ---------------------------------
# The inner script runs under tmux, detached from any SSH connection.
# It writes:
#   .current_rep        — which rep is active (read by the orchestrator's poll)
#   .sim_complete       — DONE marker on success
#   .sim_failed         — FAILED marker on any error (set by ERR trap)
#   run.log             — append-only timestamps for each rep
#   sim.log             — tee'd stdout/stderr of the inner script itself
#   rep_<NN>.stderr     — BioDynaMo's per-rep stderr (tailed for live progress)
#   rep_<NN>.stdout     — BioDynaMo's per-rep stdout
#   perf_splits/rep_<NN>.perf — perf stat output, 1-second intervals
INNER_SCRIPT="${RESULTS_DIR}/run_inner.sh"
COMPLETION_MARKER="${RESULTS_DIR}/.sim_complete"
FAILURE_MARKER="${RESULTS_DIR}/.sim_failed"
CURRENT_REP_FILE="${RESULTS_DIR}/.current_rep"

# Clean stale markers from any previous attempt.
rm -f "${COMPLETION_MARKER}" "${FAILURE_MARKER}" "${CURRENT_REP_FILE}"

cat > "${INNER_SCRIPT}" << INNER
#!/usr/bin/env bash
set -euo pipefail
set -o pipefail

# Relax nounset around thisbdm.sh — it references its own env vars
# (e.g. BDM_THISBDM_LOGLEVEL) without defaults; would die under set -u.
set +u
source "${BDM_DIR}/bin/thisbdm.sh"
set -u

trap 'echo "FAILED rep=\$(cat ${CURRENT_REP_FILE} 2>/dev/null || echo unknown) at \$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${FAILURE_MARKER}"; exit 1' ERR

echo "sim_started_at=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${RESULTS_DIR}/run.log"

for REP in 01; do
  echo "\${REP}" > "${CURRENT_REP_FILE}"
  echo "[rep \${REP}/01] starting at \$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  REP_START=\$(date -u +%Y-%m-%dT%H:%M:%SZ)

  OMP_NUM_THREADS=${CORES} perf stat \\
    -e "${PERF_EVENTS}" \\
    -I 1000 \\
    -o "${PERF_DIR}/rep_\${REP}.perf" \\
    "${BINARY}" \\
      --inline-config '${INLINE_CONFIG}' \\
      --config "${CONFIG}" \\
    > "${RESULTS_DIR}/rep_\${REP}.stdout" \\
    2> "${RESULTS_DIR}/rep_\${REP}.stderr"

  REP_END=\$(date -u +%Y-%m-%dT%H:%M:%SZ)

  {
    echo "rep_\${REP}_started_at=\${REP_START}"
    echo "rep_\${REP}_finished_at=\${REP_END}"
  } >> "${RESULTS_DIR}/run.log"

  echo "[rep \${REP}/01] done"
done

echo "sim_completed_at=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${RESULTS_DIR}/run.log"
echo "DONE" > "${COMPLETION_MARKER}"
INNER

chmod +x "${INNER_SCRIPT}"

# --- launch inside tmux and return immediately -------------------------
# Kill any leftover session from a previous failed attempt.
tmux kill-session -t "${TMUX_SESSION}" 2>/dev/null || true

# `bash inner | tee sim.log` — inner has `set -o pipefail` so a failure in
# `bash` is propagated; the ERR trap fires and writes .sim_failed.
tmux new-session -d -s "${TMUX_SESSION}" \
  "bash ${INNER_SCRIPT} 2>&1 | tee ${RESULTS_DIR}/sim.log"

echo "Simulation launched in tmux session '${TMUX_SESSION}'."
echo "Watch live with: tmux attach -t ${TMUX_SESSION}"
echo "Or tail: tail -f ${RESULTS_DIR}/sim.log"
