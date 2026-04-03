#!/usr/bin/env bash
# Run on a fresh EC2 instance (Amazon Linux 2 / Ubuntu).
# Sets up Docker, builds the fletch image, runs the multi-process vs
# multi-isolate benchmark across worker counts that go past the ~13-core plateau.
#
# Usage:
#   chmod +x ec2_bench.sh && ./ec2_bench.sh 2>&1 | tee bench_results.txt

set -euo pipefail

TOTAL_CPUS=$(nproc)
# Give server 3/4 of the machine; wrk gets 1/4
SERVER_CPUS=$(( TOTAL_CPUS * 3 / 4 ))
WRK_THREADS=$(( TOTAL_CPUS / 4 ))
DURATION=20s
CONNECTIONS=512

echo "======================================================"
echo " Fletch multi-process benchmark"
echo " Machine: ${TOTAL_CPUS} vCPUs"
echo " Server quota: ${SERVER_CPUS} CPUs | wrk threads: ${WRK_THREADS}"
echo " Duration per run: ${DURATION} | Connections: ${CONNECTIONS}"
echo "======================================================"
echo ""

# ── 1. Install Docker ──────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "[setup] Installing Docker..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y docker.io
    sudo systemctl start docker
  else
    # Amazon Linux 2
    sudo yum install -y docker
    sudo systemctl start docker
  fi
  sudo usermod -aG docker "$USER"
  # Re-exec so group change takes effect without logout
  exec sg docker "$0"
fi

# ── 2. Install wrk ────────────────────────────────────────────────────────────
if ! command -v wrk &>/dev/null; then
  echo "[setup] Installing wrk..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get install -y --no-install-recommends wrk
  else
    sudo yum install -y wrk 2>/dev/null || {
      # Build from source if not in yum
      sudo yum install -y git gcc make openssl-devel
      git clone https://github.com/wg/wrk.git /tmp/wrk
      make -C /tmp/wrk -j"$(nproc)"
      sudo cp /tmp/wrk/wrk /usr/local/bin/
    }
  fi
fi

# ── 3. Build Fletch image ─────────────────────────────────────────────────────
echo "[setup] Cloning HttpArena and building fletch image..."
if [ ! -d /tmp/HttpArena ]; then
  git clone --depth=1 --branch feat/fletch \
    https://github.com/kartikey321/HttpArena.git /tmp/HttpArena
fi
docker build -t fletch-bench /tmp/HttpArena/frameworks/fletch/
echo "[setup] Done."
echo ""

# ── 4. Benchmark helper ───────────────────────────────────────────────────────
run_case() {
  local label="$1"
  local entrypoint_override="$2"   # empty = use image default (multi-process)
  local workers="$3"

  docker rm -f fletch-test 2>/dev/null || true

  if [ -z "$entrypoint_override" ]; then
    docker run -d --name fletch-test \
      --cpus="$SERVER_CPUS" -p 8080:8080 \
      fletch-bench
  else
    docker run -d --name fletch-test \
      --cpus="$SERVER_CPUS" -p 8080:8080 \
      --entrypoint /server/bin/server \
      fletch-bench "$workers"
  fi

  # Wait for server
  for _ in $(seq 1 40); do
    curl -fsS http://localhost:8080/pipeline &>/dev/null && break
    sleep 0.3
  done

  # CPU sampler
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

  local rps avg_cpu
  rps=$(echo "$WRK_OUT"    | awk '/Requests\/sec:/{print $2}')
  avg_cpu=$(awk '{s+=$1;n++} END{if(n>0)printf "%.1f",s/n;else print "n/a"}' "$CPU_FILE")

  printf "  %-40s  req/s=%-10s  avg_cpu=%-8s\n" \
    "$label" "${rps:-n/a}" "${avg_cpu}%"

  docker rm -f fletch-test 2>/dev/null || true
}

# ── 5. Matrix ─────────────────────────────────────────────────────────────────
# Worker counts that span below and above the known ~1300% CPU plateau
WORKER_COUNTS="1 4 8 12 16 20 $(( SERVER_CPUS / 2 )) $SERVER_CPUS"

echo "--- multi-process (new: N OS processes, N EventHandlers) ---"
for N in $WORKER_COUNTS; do
  [ "$N" -gt "$SERVER_CPUS" ] && continue
  run_case "multi-process workers=$N" "" "$N"
done

echo ""
echo "--- multi-isolate single-process (old: 1 EventHandler) ---"
for N in $WORKER_COUNTS; do
  [ "$N" -gt "$SERVER_CPUS" ] && continue
  run_case "multi-isolate workers=$N" "override" "$N"
done

echo ""
echo "Done. Copy bench_results.txt for analysis."
