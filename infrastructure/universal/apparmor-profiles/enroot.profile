# CoreWeave canonical AppArmor profile for enroot unprivileged containers.
#
# Source: CoreWeave public documentation, "The default CoreWeave AppArmor
#   profile" (SUNK enroot-apparmor guide). Sourced 2026-04-29.
#
# Verbatim copy of the profile published in CoreWeave's public docs as
# "The default CoreWeave AppArmor profile". This profile name is `enroot`
# (matches the SUNK chart annotation `localhost/enroot`), distinct from the
# upstream NVIDIA enroot profile at /usr/bin/enroot-nsenter.
#
# Verification on Linux:
#   apparmor_parser -p enroot.profile
# (apparmor_parser is not available on macOS; CI/host validation required.)

#include <tunables/global>

profile enroot flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  # added
  mount,
  pivot_root,
  ptrace,

  # defaults
  network,
  capability,
  file,
  umount,

  deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
  # deny write to files not in /proc/<number>/** or /proc/sys/**
  deny @{PROC}/{[^1-9],[^1-9][^0-9],[^1-9s][^0-9y][^0-9s],[^1-9][^0-9][^0-9][^0-9/]*}/** w,
  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/kernel/security/** rwklx,
}
