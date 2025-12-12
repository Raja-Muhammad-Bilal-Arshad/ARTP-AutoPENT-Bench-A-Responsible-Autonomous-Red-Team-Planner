#!/usr/bin/env bash
# smoke_test.sh -- quick end-to-end sanity check for AutoPENT
# Place this in the repo root and run: ./smoke_test.sh
set -euo pipefail
IFS=$'\n\t'

# -----------------------
# Config (edit if needed)
# -----------------------
AGENT="${AGENT:-artp}"
TARGET="${TARGET:-web_cluster}"
RUNS=1
MODE="${MODE:-rule}"        # adapter mode to use
TIMEOUT_SECONDS=120        # kill if the whole test somehow hangs
RESULTS_BASE="results/${AGENT}/${TARGET}"

# -----------------------
# Helpers
# -----------------------
die(){ echo "[❌] $*" >&2; exit 1; }
info(){ echo "[ℹ️] $*"; }

# quick environment checks
command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH"
[[ -x "./run_experiment.sh" ]] || die "run_experiment.sh not found or not executable in repo root"

# Run a single experiment (deploy -> adapter -> verify/exec -> metrics)
info "Starting smoke test: agent=${AGENT} target=${TARGET} mode=${MODE}"

# Use a timeout to avoid infinite hangs on CI/machines (if timeout available)
if command -v timeout >/dev/null 2>&1; then
  timeout --preserve-status "${TIMEOUT_SECONDS}" ./run_experiment.sh --agent "${AGENT}" --target "${TARGET}" --runs "${RUNS}" --auto-adapter --mode "${MODE}"
else
  ./run_experiment.sh --agent "${AGENT}" --target "${TARGET}" --runs "${RUNS}" --auto-adapter --mode "${MODE}"
fi

# locate the most recent run directory for this agent/target
if [[ ! -d "${RESULTS_BASE}" ]]; then
  die "Results directory not found: ${RESULTS_BASE}"
fi

latest_run_dir=$(ls -1d "${RESULTS_BASE}"/run_* 2>/dev/null | sort | tail -n 1 || true)
[[ -n "${latest_run_dir}" ]] || die "No run directories found under ${RESULTS_BASE}"

info "Inspecting run directory: ${latest_run_dir}"

# Required artifacts to check
required_files=(
  "state.json"
  "plan.json"
  "verifier.json"
  "exec_trace.json"
  "metrics.json"
)

missing=()
for f in "${required_files[@]}"; do
  if [[ ! -f "${latest_run_dir}/${f}" ]]; then
    missing+=("${f}")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "[⚠️] Missing artifact(s) in ${latest_run_dir}: ${missing[*]}"
  echo "Contents of the run directory:"
  ls -la "${latest_run_dir}"
  die "Smoke test failed: required artifacts are missing"
fi

info "[✅] Required artifacts present."

# Optional: aggregate CSV (tools/aggregate_metrics.py) or pre-existing aggregate created by run_experiment
AGG_CSV="${RESULTS_BASE}/aggregate_metrics.csv"
if [[ -f "${AGG_CSV}" ]]; then
  info "[✅] Found aggregate CSV: ${AGG_CSV}"
else
  # try to run aggregator if available
  if [[ -f "tools/aggregate_metrics.py" ]]; then
    info "Generating aggregate CSV with tools/aggregate_metrics.py ..."
    python3 tools/aggregate_metrics.py "${RESULTS_BASE}" || echo "[⚠️] aggregate_metrics.py failed (non-fatal)"
    [[ -f "${AGG_CSV}" ]] && info "[✅] Aggregate CSV created."
  else
    echo "[⚠️] No aggregate CSV and tools/aggregate_metrics.py not found. Skipping."
  fi
fi

# Optional: produce plots if plot script exists
PLOT_SCRIPT="tools/plot_metrics.py"
if [[ -f "${PLOT_SCRIPT}" ]]; then
  info "Running plot script: ${PLOT_SCRIPT}"
  # run but don't fail the whole smoke test on plotting errors
  if python3 "${PLOT_SCRIPT}"; then
    info "[✅] Plot script completed (check plots in ${RESULTS_BASE})."
  else
    echo "[⚠️] Plot script failed (non-fatal)."
  fi
else
  info "Plot script not present at ${PLOT_SCRIPT}; skipping plotting step."
fi

# Summarize run_info / metrics content
info "Showing run_info.json and metrics.json (head)"
echo "----- run_info.json -----"
head -n 200 "${latest_run_dir}/run_info.json" 2>/dev/null || echo "(run_info.json not present)"
echo "----- metrics.json -----"
head -n 200 "${latest_run_dir}/metrics.json" 2>/dev/null || echo "(metrics.json not present)"

info "[🎉] Smoke test PASSED: basic end-to-end flow works."
echo "Results are in: ${latest_run_dir}"
