#!/usr/bin/env bash
# setup/setup_env.sh
# Runs on the remote VM after creation. Installs BioDynaMo, builds the
# epidemiology demo, configures perf privileges, and runs preflight checks.
# Called by: ssh $VM_NAME 'bash setup/setup_env.sh'
# Exit codes: 0 = success, 1 = any preflight or build failure

set -euo pipefail

echo "[1/5] Configuring perf privileges..." >&2
sudo sysctl -w kernel.perf_event_paranoid=1
# Persist without duplicating the line if setup is ever re-run on the same VM.
if ! grep -q '^kernel.perf_event_paranoid=' /etc/sysctl.conf 2>/dev/null; then
  echo 'kernel.perf_event_paranoid=1' | sudo tee -a /etc/sysctl.conf > /dev/null
fi

# Verify it took effect
PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid)
if [[ "${PARANOID}" -gt 1 ]]; then
  echo "ERROR: perf_event_paranoid is ${PARANOID}, expected <=1. Aborting." >&2
  exit 1
fi
echo "    perf_event_paranoid=${PARANOID}" >&2

# --- install BioDynaMo -------------------------------------------------
# Three env vars needed for a non-interactive install over `gcloud ssh --command`:
#   SILENT_INSTALL=1          skips prerequisites.sh's `read … </dev/tty` prompt.
#   DEBIAN_FRONTEND=noninteractive   stops apt-get from prompting (BioDynaMo's
#                              ubuntu-22.04/prerequisites.sh has a missing-`-y`
#                              `sudo apt-get install apt-transport-https`).
#   BDM_INSTALL=master        picks the master branch as the install source.
echo "[2/5] Installing BioDynaMo (master)..." >&2
export BDM_INSTALL=master
export SILENT_INSTALL=1
export DEBIAN_FRONTEND=noninteractive
curl -sSL https://biodynamo.github.io/install | bash

# Locate the installed BioDynaMo directory. The master install creates a
# VERSIONED directory at ~/biodynamo-vX.Y.Z/ (e.g. biodynamo-v1.05.152) — the
# exact version drifts over time, so we glob for it and take the highest one.
# There is no ~/biodynamo/ symlink, despite what older docs imply.
shopt -s nullglob
BDM_CANDIDATES=("${HOME}"/biodynamo-v*/)
shopt -u nullglob
if [[ ${#BDM_CANDIDATES[@]} -eq 0 ]]; then
  echo "ERROR: No installed BioDynaMo found at ~/biodynamo-v*/" >&2
  exit 1
fi
BDM_DIR=$(printf '%s\n' "${BDM_CANDIDATES[@]}" | sort -V | tail -1)
BDM_DIR="${BDM_DIR%/}"
echo "    BioDynaMo install dir: ${BDM_DIR}" >&2

# Relax nounset around the source: BioDynaMo's thisbdm.sh references some of
# its own env vars (e.g. BDM_THISBDM_LOGLEVEL) without defaulting them, so
# under `set -u` the source dies with "unbound variable". Pipefail/errexit
# stay on, so a real failure inside thisbdm.sh still trips.
# shellcheck source=/dev/null
set +u
source "${BDM_DIR}/bin/thisbdm.sh"
set -u
echo "    BioDynaMo installed and sourced" >&2


# clone the user's fork and build the epidemiology demo from it.
# The fork holds the customized measles.json AND the demo source we build
# against (upstream's binary + fork's source/config — see project memory).
echo "[3/5] Cloning fork and building epidemiology demo..." >&2
if [[ ! -d "${HOME}/biodynamo-fork" ]]; then
  git clone https://github.com/aminatpwk/biodynamo.git "${HOME}/biodynamo-fork"
fi

CONFIG_FILE="${HOME}/biodynamo-fork/demo/epidemiology/measles.json"
sed -i \
  -e 's/"initial_population_infected": [0-9]*/"initial_population_infected": 10000000/' \
  -e 's/"initial_population_susceptible": [0-9]*/"initial_population_susceptible": 190000000/' \
  -e 's/"max_bound": [0-9]*/"max_bound": 5000/' \
  "${CONFIG_FILE}"

cd "${HOME}/biodynamo-fork/demo/epidemiology"
biodynamo build

BINARY="${HOME}/biodynamo-fork/demo/epidemiology/build/epidemiology"
if [[ ! -x "${BINARY}" ]]; then
  echo "ERROR: build succeeded but binary not found at ${BINARY}." >&2
  exit 1
fi
echo "    build complete: ${BINARY}" >&2

# Confirm visualization is disabled via inline config (belt-and-suspenders)
# The run_simulation.sh script passes --inline-config to disable it at runtime,
# but we verify the binary accepts the flag here during setup.
if ! "${BINARY}" --help 2>&1 | grep -q 'inline-config'; then
  echo "WARNING: binary does not advertise --inline-config flag." >&2
  echo "         Visualization disable may not work as expected." >&2
fi

# --- preflight: hardware counter access --------------------------------
echo "[4/5] Preflight: verifying hardware PMU counter access..." >&2

# Gate 1: sysctl value
PARANOID_CHECK=$(cat /proc/sys/kernel/perf_event_paranoid)
if [[ "${PARANOID_CHECK}" -gt 1 ]]; then
  echo "ERROR: perf_event_paranoid is ${PARANOID_CHECK} after sysctl write." >&2
  exit 1
fi

# Gate 2: every counter the simulation will request must be readable.
# Probe each individually so a single broken counter is named explicitly,
# not silently recorded as <not supported> during the 36h run.
EXPERIMENT_EVENTS=(
  instructions
  cycles
  L2_RQSTS.MISS
  L2_RQSTS.REFERENCES
  MEM_LOAD_COMPLETED.L1_MISS_ANY
  MEM_LOAD_RETIRED.L1_HIT
  MEM_LOAD_RETIRED.L2_HIT
  MEM_LOAD_RETIRED.L1_MISS
  MEM_LOAD_RETIRED.L2_MISS
  TOPDOWN.SLOTS_P
  TOPDOWN.MEMORY_BOUND_SLOTS
  MEMORY_ACTIVITY.STALLS_L1D_MISS
  MEMORY_ACTIVITY.STALLS_L2_MISS
)
UNSUPPORTED=()
for EV in "${EXPERIMENT_EVENTS[@]}"; do
  # `perf stat -e EV -a sleep 0.05` returns non-zero AND prints <not supported>
  # for events the CPU doesn't expose. Capture both.
  PROBE=$(perf stat -e "${EV}" -a sleep 0.05 2>&1 || true)
  if echo "${PROBE}" | grep -qE '<not (supported|counted)>'; then
    UNSUPPORTED+=("${EV}")
  fi
done
if [[ ${#UNSUPPORTED[@]} -gt 0 ]]; then
  echo "ERROR: the following counters are not accessible on this VM:" >&2
  printf '         - %s\n' "${UNSUPPORTED[@]}" >&2
  echo "       Verify --performance-monitoring-unit=standard was set, and that" >&2
  echo "       this CPU stepping exposes the requested events." >&2
  exit 1
fi
echo "    all ${#EXPERIMENT_EVENTS[@]} PMU counters accessible" >&2

# --- log environment snapshot ------------------------------------------
echo "[5/5] Logging environment..." >&2

SETUP_LOG="${HOME}/setup_env.log"
{
  echo "setup_completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname)"
  echo "kernel=$(uname -r)"
  echo "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid)"
  echo "biodynamo_path=${HOME}/biodynamo"
  echo "epidemiology_binary=${BINARY}"
  echo "cpu_model=$(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
  echo "numa_nodes=$(lscpu | grep 'NUMA node(s)' | awk '{print $NF}')"
  echo "perf_version=$(perf --version 2>/dev/null || echo unknown)"
} > "${SETUP_LOG}"

echo "" >&2
echo "✓ setup_env.sh complete. Environment ready for simulation." >&2
echo "  Log: ${SETUP_LOG}" >&2