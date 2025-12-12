#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Activate venv (create if missing)
if [ ! -d "myenv" ]; then
    python3 -m venv myenv
fi
source myenv/bin/activate
pip install -r requirements.txt > /dev/null 2>&1 || true

export DOCKER_HOST=unix:///var/run/docker.sock

echo "[*] Cloud-only run script starting..."

# Deploy cloud stack
echo "[+] Deploying CLOUD targets..."
docker compose -f harness_targets_templates/cloud/docker-compose.yml up -d
sleep 5

# Wait until the localstack / cloud endpoint is ready (timeout 60s)
CLOUD_ENDPOINT="http://localhost:4566"
echo "[*] Waiting for CLOUD endpoint ${CLOUD_ENDPOINT} to be ready..."
READY=0
for i in $(seq 1 30); do
    if curl -s "${CLOUD_ENDPOINT}" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done

if [ "$READY" -ne 1 ]; then
    echo "[!] Cloud endpoint ${CLOUD_ENDPOINT} did not respond - aborting"
    docker compose -f harness_targets_templates/cloud/docker-compose.yml down || true
    exit 1
fi

echo "[+] Cloud endpoint responsive. Starting runs."

RUNS=${RUNS:-30}
mkdir -p tmp_orch_cloud
mkdir -p results/artp/cloud

for i in $(seq 1 $RUNS); do
    SEED=$RANDOM
    RUN_DIR="results/artp/cloud/run_${i}"
    mkdir -p "$RUN_DIR"
    echo "{\"seed\": $SEED, \"run_id\": $i}" > "$RUN_DIR/run_info.json"

    echo "[*] CLOUD Run $i/$RUNS | Seed: $SEED"

    # 1) Recon
    python3 tools/cloud_recon.py --endpoint "$CLOUD_ENDPOINT" --out tmp_orch_cloud/cloud_recon.json

    # 2) Exploit simulation (deterministic by seed)
    python3 tools/cloud_exploit_simulator.py \
        --recon tmp_orch_cloud/cloud_recon.json \
        --out tmp_orch_cloud/cloud_exploit.json \
        --seed "$SEED"

    # 3) Build state (cloud)
    python3 tools/build_state_cloud.py \
        --cloud tmp_orch_cloud/cloud_recon.json \
        --exploit tmp_orch_cloud/cloud_exploit.json \
        --out tmp_orch_cloud/cloud_state.json

    # 4) Adapter (planner)
    python3 agents/rule_based/adapter_cloud.py \
        tmp_orch_cloud/cloud_state.json \
        tmp_orch_cloud/cloud_plan.json \
        --seed "$SEED"

    # 5) Harness / grader (cloud)
    # harness/cloud_harness.py expects: --plan --exploit --metrics --run-info
    python3 harness/cloud_harness.py \
        --plan tmp_orch_cloud/cloud_plan.json \
        --exploit tmp_orch_cloud/cloud_exploit.json \
        --metrics "$RUN_DIR/metrics.json" \
        --run-info "$RUN_DIR/run_info.json"

    # Quick preview (jq prints two values)
    if command -v jq >/dev/null 2>&1; then
        echo "[#] Quick metrics preview:"
        jq '.cloudtrail_detection_rate, .mean_time_to_detect' "$RUN_DIR/metrics.json" || true
    else
        echo "[#] jq not installed — skipping quick preview"
    fi

    # small sleep to give Docker a breath
    sleep 1
done

# Aggregate cloud metrics into CSV
python3 tools/aggregate_metrics_cloud.py \
    --results-dir results/artp/cloud \
    --out results/artp/cloud/aggregate_metrics_cloud.csv

echo "[+] Completed CLOUD runs and aggregation."

# teardown
docker compose -f harness_targets_templates/cloud/docker-compose.yml down

echo "[✅] Cloud-only runs finished."

