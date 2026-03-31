#!/bin/sh
# Enable SO_REUSEPORT for all TCP sockets via LD_PRELOAD shim.
# Dart's HttpServer.bind(shared:true) only shares within one process; the shim
# makes cross-process port sharing work so each worker gets its own
# EventHandler thread and the kernel distributes connections evenly.
export LD_PRELOAD=/lib/reuseport_shim.so

# Determine effective CPU count from cgroup limits (cgroupv2 and cgroupv1),
# falling back to nproc when no limit is set.

_cpu_limit() {
    # cgroupv2: /sys/fs/cgroup/cpu.max  →  "<quota> <period>" or "max <period>"
    if [ -r /sys/fs/cgroup/cpu.max ]; then
        read -r quota period < /sys/fs/cgroup/cpu.max
        if [ "$quota" != "max" ] && [ "$period" -gt 0 ] 2>/dev/null && [ "$quota" -gt 0 ] 2>/dev/null; then
            printf '%d\n' $(( (quota + period - 1) / period ))
            return
        fi
    fi
    # cgroupv1: cpu.cfs_quota_us / cpu.cfs_period_us  (-1 = no limit)
    q=/sys/fs/cgroup/cpu/cpu.cfs_quota_us
    p=/sys/fs/cgroup/cpu/cpu.cfs_period_us
    if [ -r "$q" ] && [ -r "$p" ]; then
        quota=$(cat "$q")
        period=$(cat "$p")
        if [ "$quota" -gt 0 ] 2>/dev/null && [ "$period" -gt 0 ] 2>/dev/null; then
            printf '%d\n' $(( (quota + period - 1) / period ))
            return
        fi
    fi
    # No cgroup limit detected — use all available CPUs.
    nproc
}

n=$(_cpu_limit)

# Spawn N independent OS processes, each running a single isolate.
# Each process gets its own Dart VM EventHandler (kqueue/epoll thread),
# so I/O scales linearly with CPU count — the same model as Node.js cluster.
# The LD_PRELOAD shim above ensures SO_REUSEPORT is set so the kernel
# distributes incoming connections evenly across all N processes.
for i in $(seq 1 $((n - 1))); do
    /server/bin/server "1" &
done

# Last worker runs in the foreground as PID 1 so Docker signals reach it.
exec /server/bin/server "1"
