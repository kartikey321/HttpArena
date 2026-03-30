#!/bin/sh
# Determine effective CPU count from cgroup limits (cgroupv2 and cgroupv1),
# falling back to nproc when no limit is set.  This ensures the Dart server
# spawns exactly as many isolates as the container is allowed to use, whether
# or not the host's nproc reads the cgroup quota correctly.

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

exec /server/bin/server "$(_cpu_limit)"
