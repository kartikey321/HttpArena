#!/usr/bin/env bash
# Run the Fletch multi-process vs multi-isolate benchmark on a GCP spot VM.
# Run this from your local machine — it creates the VM, runs the bench, prints
# results, then deletes the VM automatically.
#
# Prerequisites:
#   gcloud CLI authenticated + project set
#   git (to push latest server.dart / entrypoint.sh before building)
#
# Usage:
#   chmod +x gcp_bench.sh && ./gcp_bench.sh 2>&1 | tee bench_results.txt

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
PROJECT=$(gcloud config get-value project 2>/dev/null)
ZONE="${ZONE:-us-central1-a}"
MACHINE="${MACHINE:-c3-highcpu-88}"   # 88 vCPUs, ~$0.36/hr spot
VM_NAME="fletch-bench-$(date +%s)"
REPO_URL="https://github.com/kartikey321/HttpArena.git"
REPO_BRANCH="perf/fletch-multiprocess"

echo "======================================================"
echo " Fletch benchmark — GCP spot VM"
echo " Project : $PROJECT"
echo " Zone    : $ZONE"
echo " Machine : $MACHINE  (spot)"
echo " VM name : $VM_NAME"
echo "======================================================"
echo ""

# ── 1. Create spot VM ──────────────────────────────────────────────────────────
echo "[gcp] Creating VM..."
gcloud compute instances create "$VM_NAME" \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --machine-type="$MACHINE" \
  --provisioning-model=SPOT \
  --instance-termination-action=DELETE \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=20GB \
  --metadata=startup-script='#! /bin/bash
    apt-get update -qq
    apt-get install -y docker.io git curl
    systemctl start docker
    usermod -aG docker $(logname 2>/dev/null || echo debian)' \
  --scopes=default \
  --quiet
echo "[gcp] VM created: $VM_NAME"

# Cleanup trap — always delete VM on exit
cleanup() {
  echo ""
  echo "[gcp] Deleting VM $VM_NAME ..."
  gcloud compute instances delete "$VM_NAME" \
    --project="$PROJECT" --zone="$ZONE" --quiet 2>/dev/null || true
  echo "[gcp] Done."
}
trap cleanup EXIT

# ── 2. Wait for SSH to be ready ────────────────────────────────────────────────
echo "[gcp] Waiting for SSH..."
for i in $(seq 1 40); do
  gcloud compute ssh "$VM_NAME" \
    --project="$PROJECT" --zone="$ZONE" \
    --command="echo ready" --quiet 2>/dev/null && break
  sleep 5
done

# ── 3. Upload gcp_run.sh to the VM ────────────────────────────────────────────
# All the heavy lifting runs remotely so we don't need to keep a local SSH conn.
cat > /tmp/gcp_run.sh << 'REMOTE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

REPO_URL="__REPO_URL__"
REPO_BRANCH="__REPO_BRANCH__"

TOTAL_CPUS=$(nproc)
SERVER_CPUS=$(( TOTAL_CPUS * 3 / 4 ))
WRK_THREADS=$(( TOTAL_CPUS / 4 ))
DURATION=20s
CONNECTIONS=512

echo "======================================================"
echo " Machine: ${TOTAL_CPUS} vCPUs"
echo " Server quota: ${SERVER_CPUS} CPUs | wrk threads: ${WRK_THREADS}"
echo " Duration: ${DURATION} | Connections: ${CONNECTIONS}"
echo "======================================================"

# Install wrk
if ! command -v wrk &>/dev/null; then
  apt-get install -y --no-install-recommends wrk 2>/dev/null || {
    apt-get install -y gcc make libssl-dev git
    git clone https://github.com/wg/wrk.git /tmp/wrk
    make -C /tmp/wrk -j"$(nproc)"
    cp /tmp/wrk/wrk /usr/local/bin/
  }
fi

# Build image
echo "[setup] Cloning & building fletch image..."
git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" /tmp/HttpArena
docker build -t fletch-bench /tmp/HttpArena/frameworks/fletch/
echo "[setup] Build done."
echo ""

run_case() {
  local label="$1"
  local use_default_entrypoint="$2"
  local workers="$3"

  docker rm -f fletch-test 2>/dev/null || true

  if [ "$use_default_entrypoint" = "yes" ]; then
    docker run -d --name fletch-test \
      --cpus="$SERVER_CPUS" -p 8080:8080 \
      fletch-bench
  else
    docker run -d --name fletch-test \
      --cpus="$SERVER_CPUS" -p 8080:8080 \
      --entrypoint /server/bin/server \
      fletch-bench "$workers"
  fi

  # Wait for server to be ready
  for _ in $(seq 1 40); do
    curl -fsS http://localhost:8080/pipeline &>/dev/null && break
    sleep 0.3
  done

  # CPU sampler in background
  CPU_FILE=$(mktemp)
  (while docker ps --format '{{.Names}}' | grep -q fletch-test 2>/dev/null; do
     docker stats --no-stream --format '{{.CPUPerc}}' fletch-test \
       2>/dev/null | tr -d '%' >> "$CPU_FILE"
     sleep 1
   done) &
  SAMPLER=$!

  WRK_OUT=$(wrk -t"$WRK_THREADS" -c"$CONNECTIONS" -d"$DURATION" \
    http://localhost:8080/pipeline 2>&1)

  kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null

  # Collect /metrics from one process for latency percentiles
  METRICS_JSON=$(curl -fsS http://localhost:8080/metrics 2>/dev/null || echo '{}')
  p99=$(echo "$METRICS_JSON"  | grep -o '"p99_latency_us":[0-9]*' | cut -d: -f2)
  p999=$(echo "$METRICS_JSON" | grep -o '"p999_latency_us":[0-9]*' | cut -d: -f2)
  rss=$(echo "$METRICS_JSON"  | grep -o '"rss_mb":"[^"]*"' | cut -d'"' -f4)

  # Parse --verbose-gc lines from container stderr: "[ GC ... pause XXXms ]"
  GC_LOG=$(docker logs fletch-test 2>&1 | grep -i '\bpause\b' || true)
  gc_count=$(echo "$GC_LOG" | grep -c 'pause' 2>/dev/null || echo 0)
  gc_max_ms=$(echo "$GC_LOG" | grep -oP '\d+\.\d+(?=ms)' | sort -n | tail -1 || echo 0)

  rps=$(echo "$WRK_OUT" | awk '/Requests\/sec:/{print $2}')
  avg_cpu=$(awk '{s+=$1;n++} END{if(n>0)printf "%.1f",s/n;else print "n/a"}' "$CPU_FILE")
  rm -f "$CPU_FILE"

  printf "  %-45s  req/s=%-10s  cpu=%-6s  p99=%sus  p999=%sus  rss=%sMB  gc=%s(max %sms)\n" \
    "$label" "${rps:-n/a}" "${avg_cpu}%" \
    "${p99:-?}" "${p999:-?}" "${rss:-?}" \
    "${gc_count}" "${gc_max_ms}"

  docker rm -f fletch-test 2>/dev/null || true
}

# Start at 8 — below-plateau data isn't interesting; go well past the ~13-core
# EventHandler ceiling to show where multi-process keeps climbing.
WORKER_COUNTS="8 12 16 20 24 32 48 $(( SERVER_CPUS / 2 )) $SERVER_CPUS"

echo "--- multi-process (N OS processes × 1 isolate, N EventHandlers) ---"
for N in $WORKER_COUNTS; do
  [ "$N" -gt "$SERVER_CPUS" ] && continue
  run_case "multi-process  workers=$N" "yes" "$N"
done

echo ""
echo "--- multi-isolate single-process (N isolates, 1 EventHandler) ---"
for N in $WORKER_COUNTS; do
  [ "$N" -gt "$SERVER_CPUS" ] && continue
  run_case "multi-isolate  workers=$N" "no" "$N"
done

echo ""
echo "=== Benchmark complete ==="
REMOTE_SCRIPT

# Substitute repo vars into the script
sed -i '' "s|__REPO_URL__|${REPO_URL}|g" /tmp/gcp_run.sh
sed -i '' "s|__REPO_BRANCH__|${REPO_BRANCH}|g" /tmp/gcp_run.sh

gcloud compute scp /tmp/gcp_run.sh "$VM_NAME":/tmp/gcp_run.sh \
  --project="$PROJECT" --zone="$ZONE" --quiet

# ── 4. Run benchmark on VM ─────────────────────────────────────────────────────
echo "[gcp] Starting benchmark (this takes ~10-15 min)..."
echo ""
gcloud compute ssh "$VM_NAME" \
  --project="$PROJECT" --zone="$ZONE" \
  --command="sudo bash /tmp/gcp_run.sh" \
  --quiet

# cleanup trap fires on exit → VM deleted automatically
