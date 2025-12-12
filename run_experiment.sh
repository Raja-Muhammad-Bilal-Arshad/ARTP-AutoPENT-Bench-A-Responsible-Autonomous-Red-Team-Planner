#!/usr/bin/env bash
# run_experiment.sh -- enhanced with progress indicators & run duration tracking
# Usage: ./run_experiment.sh --agent AGENT_NAME --target TARGET_NAME --runs N --auto-adapter --mode rule
# Example: ./run_experiment.sh --agent artp --target web_cluster --runs 5 --auto-adapter --mode rule

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Defaults (edit if you want)
# -------------------------
AGENT="artp"
TARGET="web_cluster"
N_RUNS=5
SEEDS=(42 43 44 45 46)
TIME_BUDGET=300
RESULTS_DIR="results"
LOG_LEVEL="info"
AUTO_ADAPTER=false
MODE="rule"   # mode passed to adapter when auto-adapter used
AUTO_APPROVE=false

# top of script default LLM settings (optional)
LLM_MODE="${LLM_MODE:-local}"     # "local" or "api"
LLM_MODEL="${LLM_MODEL:-llama3}"  # model name for adapter_llm.py
SANDBOX="${SANDBOX:-true}"        # enforce sandbox by default

# harness script name expected inside harness/ directory
HARNESS_PY_IN_DIR="harness.py"

# -------------------------
# Arg parsing
# -------------------------
print_help() {
  cat <<'USAGE'
Usage: ./run_experiment.sh [--agent AGENT] [--target TARGET] [--runs N] [--time SECONDS] [--auto-adapter] [--mode rule|llm] [--auto-approve] [--help]

Examples:
  ./run_experiment.sh --agent artp --target web_cluster --runs 5
  ./run_experiment.sh --agent artp --target web_cluster --runs 3 --auto-adapter --mode rule

USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2;;
    --target) TARGET="$2"; shift 2;;
    --runs) N_RUNS="$2"; shift 2;;
    --time) TIME_BUDGET="$2"; shift 2;;
    --auto-adapter) AUTO_ADAPTER=true; shift 1;;
    --mode) MODE="$2"; shift 2;;
    --auto-approve) AUTO_APPROVE=true; shift 1;;
    --help) print_help; exit 0;;
    *) echo "Unknown arg: $1"; print_help; exit 1;;
  esac
done

# -------------------------
# Locate harness executable
# -------------------------
HARNESS_CMD=""
HARNESS_TYPE=""

if [[ -f "./harness" && -x "./harness" ]]; then
  HARNESS_CMD="./harness"
  HARNESS_TYPE="exe"
elif [[ -f "./harness.sh" && -x "./harness.sh" ]]; then
  HARNESS_CMD="./harness.sh"
  HARNESS_TYPE="exe"
elif [[ -d "./harness" && -f "./harness/${HARNESS_PY_IN_DIR}" ]]; then
  HARNESS_CMD="python3 ./harness/${HARNESS_PY_IN_DIR}"
  HARNESS_TYPE="py"
elif [[ -f "./harness.py" ]]; then
  HARNESS_CMD="python3 ./harness.py"
  HARNESS_TYPE="py"
else
  echo "❌ Could not find harness CLI. Expected one of:"
  echo "   ./harness (executable file)"
  echo "   ./harness.sh (launcher)"
  echo "   ./harness/${HARNESS_PY_IN_DIR} (inside directory)"
  echo "   ./harness.py (in repo root)"
  exit 2
fi

echo "[*] Using harness command: $HARNESS_CMD"

# -------------------------
# Sanity checks
# -------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 required but not found in PATH" >&2
  exit 3
fi

mkdir -p "$RESULTS_DIR/$AGENT/$TARGET"

# deploy target
echo "[+] Deploying target: $TARGET"
$HARNESS_CMD deploy "$TARGET"

# trap teardown on exit
_teardown() {
  echo "[*] Tearing down target: $TARGET"
  $HARNESS_CMD teardown "$TARGET" --force || true
}
trap _teardown EXIT

# run experiment runs
# if N_RUNS is not numeric, coerce
if ! [[ "$N_RUNS" =~ ^[0-9]+$ ]]; then
  echo "Invalid --runs value: $N_RUNS" >&2
  exit 4
fi

for i in $(seq 1 "$N_RUNS"); do
  seed="${SEEDS[$((i-1))]}"
  run_id="run_${TARGET}_${AGENT}_seed${seed}_$(date -u +%Y%m%dT%H%M%SZ)"
  outdir="$RESULTS_DIR/$AGENT/$TARGET/$run_id"
  mkdir -p "$outdir"

  echo
  echo "[🚀] Run $i / $N_RUNS (seed=$seed) -> $outdir"
  start_ts_wall=$(date --utc +"%Y-%m-%dT%H:%M:%SZ")
  start_ts_epoch=$(date +%s)

  # 1) produce or copy state.json
  if [[ -f "./state.json" ]]; then
    echo "[📄] Using existing state.json in repo root"
    cp ./state.json "$outdir/state.json"
  else
    echo "[🔎] Dumping state using harness"
    $HARNESS_CMD dump_state --target "$TARGET" --out "$outdir/state.json" --seed "$seed"
  fi

  # 2) adapter invocation (if plan missing and auto-adapter requested)
  plan_path="$outdir/plan.json"
  if [[ ! -f "$plan_path" ]]; then
    if [[ "$AUTO_ADAPTER" == "true" ]]; then
      echo "[*] Auto-adapter enabled: generating plan for mode='$MODE'"

      # Choose adapter program depending on the mode (rule vs llm)
      ADAPTER_SCRIPT=""
      ADAPTER_ARGS=""

      if [[ "$MODE" == "rule" ]]; then
        ADAPTER_SCRIPT="agents/artp/adapter.py"
        ADAPTER_ARGS="--mode rule"
      elif [[ "$MODE" == "llm" ]]; then
        # Use adapter_llm, accept LLM_MODE and LLM_MODEL env vars (or defaults)
        ADAPTER_SCRIPT="agents/artp/adapter_llm.py"
        LLM_MODE="${LLM_MODE:-local}"      # default: local (ollama/llama)
        LLM_MODEL="${LLM_MODEL:-llama3}"   # default model name
        ADAPTER_ARGS="--mode llm --model ${LLM_MODEL} --llm-mode ${LLM_MODE}"
        # if you want sandbox safety enforcement set --sandbox when running in test
        if [[ "${SANDBOX:-true}" == "true" ]]; then
          ADAPTER_ARGS="${ADAPTER_ARGS} --sandbox"
        fi
      else
        echo "[!] Unknown MODE='$MODE' — expected 'rule' or 'llm'." >&2
        exit 6
      fi

      # Ensure adapter script exists
      if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        echo "[!] Adapter script not found: $ADAPTER_SCRIPT" >&2
        echo "    Please create agents/artp/adapter.py (rule) or agents/artp/adapter_llm.py (llm)."
        exit 7
      fi

      # Run the adapter to produce plan.json
      # Run adapter with explicit, separate args to avoid shell-word-splitting issues
      if [[ "$MODE" == "rule" ]]; then
        echo "[*] Running adapter: python3 $ADAPTER_SCRIPT $outdir/state.json $plan_path --mode rule --seed $seed"
        python3 "$ADAPTER_SCRIPT" "$outdir/state.json" "$plan_path" --mode "rule" --seed "$seed"
        ADAPTER_EXIT=$?
      else
        # llm mode: pass explicit LLM args
        echo "[*] Running adapter: python3 $ADAPTER_SCRIPT $outdir/state.json $plan_path --mode llm --model ${LLM_MODEL} --llm-mode ${LLM_MODE} ${SANDBOX:+--sandbox} --seed $seed"
        python3 "$ADAPTER_SCRIPT" "$outdir/state.json" "$plan_path" --mode "llm" --model "${LLM_MODEL}" --llm-mode "${LLM_MODE}" ${SANDBOX:+--sandbox} --seed "$seed"
        ADAPTER_EXIT=$?
      fi

      if [[ $ADAPTER_EXIT -ne 0 ]]; then
        echo "[!] Adapter failed (exit=$ADAPTER_EXIT)" >&2
        exit $ADAPTER_EXIT
      fi

      # After adapter completes, continue by invoking harness to verify/execute plan
      echo "[*] Adapter completed; invoking harness to verify & execute plan"
      $HARNESS_CMD run_plan --plan "$plan_path" --outdir "$outdir" --time_budget "$TIME_BUDGET" --agent "$AGENT" --mode "$MODE" --seed "$seed" ${AUTO_APPROVE:+--auto-approve}

    else
      echo "[!] plan.json not found at $plan_path and --auto-adapter not set. Please provide plan.json or re-run with --auto-adapter" >&2
      exit 5
    fi
  else
    # if plan exists, call harness to run_plan normally
    echo "[*] plan.json exists; invoking harness to verify & execute"
    $HARNESS_CMD run_plan --plan "$plan_path" --outdir "$outdir" --time_budget "$TIME_BUDGET" --agent "$AGENT" --mode "$MODE" --seed "$seed" ${AUTO_APPROVE:+--auto-approve}
  fi

  # capture end time & compute duration
  end_ts_wall=$(date --utc +"%Y-%m-%dT%H:%M:%SZ")
  end_ts_epoch=$(date +%s)
  duration=$((end_ts_epoch - start_ts_epoch))
  # format duration HH:MM:SS
  hrs=$((duration/3600))
  mins=$(((duration%3600)/60))
  secs=$((duration%60))
  duration_fmt=$(printf "%02d:%02d:%02d" "$hrs" "$mins" "$secs")

  # write run_info.json
  run_info_path="$outdir/run_info.json"
  cat > "$run_info_path" <<JSON
{
  "run_id": "$run_id",
  "agent": "$AGENT",
  "target": "$TARGET",
  "seed": $seed,
  "start_time_utc": "$start_ts_wall",
  "end_time_utc": "$end_ts_wall",
  "duration_seconds": $duration,
  "duration_hms": "$duration_fmt"
}
JSON

  echo "[⏱️] Run $i / $N_RUNS finished in $duration_fmt"
  # show where run_info was saved
  echo "[💾] Saved run info: $run_info_path"

  # report metrics saved (if harness wrote metrics.json)
  metrics_path="$outdir/metrics.json"
  if [[ -f "$metrics_path" ]]; then
    echo "[💾] Metrics saved: $metrics_path"
  else
    echo "[⚠️] No metrics.json found in $outdir (verifier may have held the run or auto-approve off)"
  fi

  echo "[+] Run complete: $run_id"
done

# -------------------------
# 🧠 Aggregate metrics (fancy output)
# -------------------------
echo -e "\n[🧠] Aggregating metrics into CSV...\n"

if [[ ! -d "results/${AGENT}/${TARGET}" ]]; then
  echo -e "[⚠️] No results directory found at results/${AGENT}/${TARGET}"
  exit 1
fi

python3 tools/aggregate_metrics.py "results/${AGENT}/${TARGET}"

if [[ $? -eq 0 ]]; then
  echo -e "\n[✅] All runs complete!"
  echo -e "📂 Results stored in: \033[1;36mresults/${AGENT}/${TARGET}\033[0m\n"
else
  echo -e "\n[❌] Aggregation failed. Check logs above.\n"
fi

