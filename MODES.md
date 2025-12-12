#!/bin/bash
# ==============================================================
#  AutoPENT — All Modes + Full Command Reference
# ==============================================================

# --- [0] Setup Base Environment --------------------------------
# Create venv and install requirements (latest)
python3 -m venv myenv
source myenv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# --- [1] Fix Docker Socket (Podman conflict fix) ---------------
export DOCKER_HOST=unix:///var/run/docker.sock

# --- [2] Deploy Web Cluster ------------------------------------
cd harness_targets_templates/web_cluster
docker-compose up -d --remove-orphans
cd ../../..

# --- [3] Verify Containers -------------------------------------
docker ps

# --- [4] Manual Recon + Probe + Crawl ---------------------------
mkdir -p tmp_orch
python3 tools/recon_service.py --host 127.0.0.1 --port 8081 --out tmp_orch/recon_service.json
python3 tools/dir_probe.py --host 127.0.0.1 --port 8081 --out tmp_orch/dir_probe.json
python3 tools/crawl_and_extract.py --host 127.0.0.1 --port 8081 --paths / /login --out tmp_orch/crawl.json
python3 tools/build_state.py --dir tmp_orch --out state_from_live.json

# --- [5] Prepare Harness Input ---------------------------------
cp state_from_live.json state.json

# --- [6] Run Harness (Rule-Based Mode) --------------------------
python3 harness/harness.py run_plan \
    --plan plan.json \
    --outdir results/manual_run_rule \
    --agent rule_based \
    --auto-adapter \
    --mode rule \
    --auto-approve

# --- [7] Run Harness (Auto Mode) -------------------------------
python3 harness/harness.py run_plan \
    --plan plan.json \
    --outdir results/manual_run_auto \
    --agent auto_agent \
    --auto-adapter \
    --mode auto \
    --auto-approve

# --- [8] Run Harness (Hybrid Mode) -----------------------------
python3 harness/harness.py run_plan \
    --plan plan.json \
    --outdir results/manual_run_hybrid \
    --agent hybrid_agent \
    --auto-adapter \
    --mode hybrid \
    --auto-approve

# --- [9] Run Full Orchestrator Script ---------------------------
bash tools/orchestrator_run.sh

# --- [10] Aggregate Metrics ------------------------------------
python3 tools/aggregate_metrics.py results/artp/web_cluster

# --- [11] Plot Metrics (IEEE-style dots) -----------------------
python3 tools/plot_metrics.py results/artp/web_cluster/aggregate_metrics.csv results/plots/

# --- [12] Export Results as ZIP -------------------------------
zip -r results_$(date +%Y%m%dT%H%M%S).zip results/

# --- [13] Stop & Clean Containers ------------------------------
cd harness_targets_templates/web_cluster
docker-compose down
cd ../../..

# --- [14] Auto Full Pipeline (One Command) ---------------------
bash auto_run.sh

# --- [15] FOR AD-After SharpHound have the data 
python3 ./harness/harness.py run_plan --plan plan.json --outdir results/ad_run --agent artp --auto-adapter --mode rule --auto-approve



