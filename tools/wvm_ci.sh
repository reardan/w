#!/usr/bin/env bash
# Required real-VM gate. The caller supplies a pinned Linux kernel and a
# delegated cgroup-v2 parent. This script never installs tools or skips tests.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${WVM_TEST_KERNEL:?set WVM_TEST_KERNEL to a pinned x64 Linux bzImage}"
: "${WVM_TEST_CGROUP:?set WVM_TEST_CGROUP to a delegated cgroup-v2 parent}"
test -r "$WVM_TEST_KERNEL"
test -r /dev/kvm && test -w /dev/kvm
command -v qemu-system-x86_64 >/dev/null
command -v python3 >/dev/null
test -w "$WVM_TEST_CGROUP/cgroup.procs"
test -w "$WVM_TEST_CGROUP/cgroup.subtree_control"
for controller in cpu memory pids; do
    if ! tr ' ' '\n' < "$WVM_TEST_CGROUP/cgroup.subtree_control" | grep -qx "$controller"; then
        echo "missing delegated controller: $controller" >&2
        exit 1
    fi
done
unset W_CI_NO_KVM
export W_CI_NO_SKIP=1
log=$(mktemp)
trap 'rm -f "$log"' EXIT
./wbuild manifest
mapfile -t targets < <(python3 - <<'PY'
import json, re
manifest = json.load(open('bin/build.json'))
for target in manifest['targets']:
    name = target['name']
    if name in ('memfd_test', 'memfd_64_test', 'kvm_hello_test', 'wexec_cell_test') or re.fullmatch(r'wvm.*_test', name):
        print(name)
PY
)
test "${#targets[@]}" -ge 17
./wbuild --no-cache "${targets[@]}" "$@" 2>&1 | tee "$log"
if grep -a -q 'SKIP' "$log"; then
    echo 'required VM gate encountered a skipped test' >&2
    exit 1
fi
