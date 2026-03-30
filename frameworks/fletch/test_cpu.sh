#!/bin/sh
# Run with: sh test_cpu.sh [cpu_limit]
# Example:  sh test_cpu.sh 3
CPU_LIMIT="${1:-3}"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Running inside Docker with --cpus=$CPU_LIMIT ..."
echo ""

docker run --rm \
  --cpus="$CPU_LIMIT" \
  -v "$DIR/test_cpu.dart:/tmp/check.dart:ro" \
  dart:stable \
  dart /tmp/check.dart
