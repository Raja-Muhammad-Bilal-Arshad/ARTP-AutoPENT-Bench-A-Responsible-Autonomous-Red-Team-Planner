#!/bin/bash
# ==============================================================
# AutoPENT One-Command Orchestrator (WEB + CLOUD - Black Hat)
# 30 Runs Each | Fully Dynamic | Separate Metrics
# ==============================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[*] Starting AutoPENT WEB + CLOUD Experiment Pipeline..."

# --------------------------------------------------------------
# 1. Python Environment
# --------------------------------------------------------------
if [ ! -d "myenv" ]; then
    python3 -m venv myenv
fi

source myenv/bin/activate
pip install -r requirements.txt > /dev/null 2>&1 || true

export DOCKER_HOST=unix:///var/run/docker.sock

# ==============================================================
# ======================== WEB PIPELINE ========================
# ==============================================================

echo "[+] Deploying WEB targets..."
cd harness_targets_templates/web_cluster
docker compose up -d --remove-orphans
cd "$SCRIPT_DIR"
sleep 8

RUNS=30
echo "[*] Starting $RUNS WEB experimental runs..."

for i in $(seq 1 $RUNS); do
    # Dynamic Seed: Random + Index
    SEED=$((RANDOM + i))
    echo "   [WEB Run $i/$RUNS] Seed: $SEED"

    mkdir -p tmp_orch

    # Run Tools
    python3 tools/recon_service.py --host 127.0.0.1 --port 8081 --out tmp_orch/recon.json
    python3 tools/dir_probe.py --host 127.0.0.1 --port 8081 --out tmp_orch/dir.json
    python3 tools/crawl_and_extract.py --host 127.0.0.1 --port 8081 --paths / /login --out tmp_orch/crawl.json

    cp tmp_orch/crawl.json tmp_orch/forms.json
    cp tmp_orch/crawl.json tmp_orch/check_creds.json

    python3 tools/exploit_simulator.py \
        --crawl tmp_orch/crawl.json \
        --check tmp_orch/check_creds.json \
        --out tmp_orch/exploit_sim.json \
        --seed $SEED

    python3 tools/build_state.py --dir tmp_orch --out state_from_live.json
    cp state_from_live.json state.json

    # Unique Directory based on Seed (Prevents Overwrite)
    RUN_DIR="results/artp/web_cluster/run_${SEED}"
    mkdir -p "$RUN_DIR"

    echo "{\"seed\": $SEED, \"run_id\": $i}" > "$RUN_DIR/run_info.json"

    python3 harness/harness.py run_plan \
        --plan plan.json \
        --outdir "$RUN_DIR" \
        --agent rule_based \
        --auto-adapter \
        --mode rule \
        --auto-approve > /dev/null
done

echo "[*] Aggregating WEB metrics..."
python3 tools/aggregate_metrics.py results/artp/web_cluster

echo "[+] Tearing down WEB targets..."
cd harness_targets_templates/web_cluster
docker compose down
cd "$SCRIPT_DIR"

# ==============================================================
# ======================= CLOUD PIPELINE =======================
# ==============================================================

echo "[+] Deploying CLOUD targets..."
docker compose -f harness_targets_templates/cloud/docker-compose.yml up -d
sleep 10

# Create plans directory
mkdir -p plans
mkdir -p tmp_orch_cloud

echo "[*] Starting $RUNS CLOUD experimental runs..."

for i in $(seq 1 $RUNS); do
    # Dynamic Seed: Random + Date (Ensures total uniqueness even across re-runs)
    SEED=$((RANDOM + $(date +%s%N | cut -b1-4)))
    
    # Save Results to UNIQUE folder
    RUN_DIR="results/artp/cloud/run_${SEED}"
    mkdir -p "$RUN_DIR"

    echo "[*] Starting CLOUD Run $i/$RUNS | Seed: $SEED | Dir: $RUN_DIR"

    # -----------------------------
    # 1. CLOUD RECON
    # -----------------------------
    python3 tools/cloud_recon.py \
        --endpoint http://localhost:4566 \
        --out tmp_orch_cloud/cloud_recon.json

    # -----------------------------
    # 2. CLOUD EXPLOIT SIM
    # -----------------------------
    python3 tools/cloud_exploit_simulator.py \
        --recon tmp_orch_cloud/cloud_recon.json \
        --out tmp_orch_cloud/cloud_exploit.json \
        --seed "$SEED"

    # -----------------------------
    # 3. CLOUD STATE BUILD
    # -----------------------------
    python3 tools/build_state_cloud.py \
        --cloud tmp_orch_cloud/cloud_recon.json \
        --exploit tmp_orch_cloud/cloud_exploit.json \
        --out tmp_orch_cloud/cloud_state.json

    # -----------------------------
    # 4. CLOUD ADAPTER (Generates Plan)
    # -----------------------------
    python3 agents/rule_based/adapter_cloud.py \
        tmp_orch_cloud/cloud_state.json \
        tmp_orch_cloud/cloud_plan.json \
        --seed "$SEED"

    # -----------------------------
    # 5. CLOUD HARNESS (Executes & Scores)
    # -----------------------------
    echo "{\"seed\": $SEED, \"run_id\": $i}" > "$RUN_DIR/run_info.json"

    python3 harness/cloud_harness.py \
        --plan tmp_orch_cloud/cloud_plan.json \
        --exploit tmp_orch_cloud/cloud_exploit.json \
        --metrics "$RUN_DIR/metrics.json" \
        --run-info "$RUN_DIR/run_info.json"

    # -----------------------------
    # 6. ARCHIVE ARTIFACTS (Black Hat Standard)
    # -----------------------------
    # Save the actual plan and recon data for this run so we can audit it later
    cp tmp_orch_cloud/cloud_plan.json "$RUN_DIR/plan.json"
    cp tmp_orch_cloud/cloud_recon.json "$RUN_DIR/recon.json"

done

# -----------------------------
# 7. FINAL CLOUD AGGREGATION
# -----------------------------
echo "[*] Aggregating ALL Cloud Runs..."
python3 tools/aggregate_metrics_cloud.py \
    --results-dir results/artp/cloud \
    --out results/artp/cloud/aggregate_metrics_cloud.csv

echo "[✅] Cloud Aggregation Complete."

echo "[+] Tearing down CLOUD targets..."
cd harness_targets_templates/cloud
docker compose down
cd "$SCRIPT_DIR"

# ==============================================================
# =========================== DONE =============================
# ==============================================================

echo "[✅] ALL WEB + CLOUD EXPERIMENTS COMPLETE"
echo "WEB  → results/artp/web_cluster/aggregate_metrics.csv"
echo "CLOUD → results/artp/cloud/aggregate_metrics_cloud.csv"
