import 'dart:io';

Future<void> main() async {
  final platformCpus = Platform.numberOfProcessors;

  final nprocResult = await Process.run('nproc', []);
  final nprocCpus = int.tryParse(nprocResult.stdout.toString().trim()) ?? -1;

  String cgroupV2 = 'not found';
  try { cgroupV2 = File('/sys/fs/cgroup/cpu.max').readAsStringSync().trim(); } catch (_) {}

  String cgroupV1Quota = 'not found';
  String cgroupV1Period = 'not found';
  try { cgroupV1Quota = File('/sys/fs/cgroup/cpu/cpu.cfs_quota_us').readAsStringSync().trim(); } catch (_) {}
  try { cgroupV1Period = File('/sys/fs/cgroup/cpu/cpu.cfs_period_us').readAsStringSync().trim(); } catch (_) {}

  print('Platform.numberOfProcessors : $platformCpus');
  print('nproc                       : $nprocCpus');
  print('cgroupv2 /cpu.max           : $cgroupV2');
  print('cgroupv1 cfs_quota_us       : $cgroupV1Quota');
  print('cgroupv1 cfs_period_us      : $cgroupV1Period');
}
