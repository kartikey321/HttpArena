#!/bin/sh
# Prints Platform.numberOfProcessors vs nproc vs raw cgroup values.
# Run with: sh test_cpu.sh [cpu_limit]
# Example:  sh test_cpu.sh 3

CPU_LIMIT="${1:-3}"

DART_SCRIPT='
import "dart:io";

Future<void> main() async {
  final platformCpus = Platform.numberOfProcessors;

  // nproc
  final nprocResult = await Process.run("nproc", []);
  final nprocCpus = int.tryParse(nprocResult.stdout.toString().trim()) ?? -1;

  // raw cgroup v2
  String cgroupV2 = "not found";
  try { cgroupV2 = File("/sys/fs/cgroup/cpu.max").readAsStringSync().trim(); } catch (_) {}

  // raw cgroup v1
  String cgroupV1Quota = "not found";
  String cgroupV1Period = "not found";
  try { cgroupV1Quota = File("/sys/fs/cgroup/cpu/cpu.cfs_quota_us").readAsStringSync().trim(); } catch (_) {}
  try { cgroupV1Period = File("/sys/fs/cgroup/cpu/cpu.cfs_period_us").readAsStringSync().trim(); } catch (_) {}

  print("Platform.numberOfProcessors : \$platformCpus");
  print("nproc                       : \$nprocCpus");
  print("cgroupv2 /cpu.max           : \$cgroupV2");
  print("cgroupv1 cfs_quota_us       : \$cgroupV1Quota");
  print("cgroupv1 cfs_period_us      : \$cgroupV1Period");
}
'

echo "Running inside Docker with --cpus=$CPU_LIMIT ..."
echo ""

docker run --rm \
  --cpus="$CPU_LIMIT" \
  dart:stable \
  sh -c "echo '$DART_SCRIPT' > /tmp/check.dart && dart /tmp/check.dart"
