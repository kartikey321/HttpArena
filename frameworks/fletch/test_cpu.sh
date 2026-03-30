#!/bin/sh
# Prints Platform.numberOfProcessors vs nproc inside a Docker container.
# Run with: sh test_cpu.sh [cpu_limit]
# Example:  sh test_cpu.sh 3
#
# On a 6-core VPS with --cpus=3 you should see:
#   Platform.numberOfProcessors = 6   (sees all host CPUs — WRONG for benchmarks)
#   nproc                        = 3   (respects the cgroup quota — CORRECT)

CPU_LIMIT="${1:-3}"

DART_SCRIPT='
import "dart:io";
import "dart:convert";

Future<void> main() async {
  final platformCpus = Platform.numberOfProcessors;
  final nprocResult = await Process.run("nproc", []);
  final nprocCpus = int.tryParse(nprocResult.stdout.toString().trim()) ?? -1;

  print("Platform.numberOfProcessors : $platformCpus");
  print("nproc                       : $nprocCpus");

  if (platformCpus != nprocCpus) {
    print("");
    print("MISMATCH — spawning \$platformCpus isolates wastes cores.");
    print("Use nproc to get the cgroup-correct count (\$nprocCpus).");
  } else {
    print("");
    print("OK — both agree on \$platformCpus.");
  }
}
'

echo "Running inside Docker with --cpus=$CPU_LIMIT ..."
echo ""

docker run --rm \
  --cpus="$CPU_LIMIT" \
  dart:stable \
  sh -c "echo '$DART_SCRIPT' > /tmp/check.dart && dart /tmp/check.dart"
