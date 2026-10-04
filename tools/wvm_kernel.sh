#!/bin/sh
# Build a caller-supplied Linux source tree; no downloads or installation.
# Keep source provenance/pins with your deployment. Output includes .config.
set -eu
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo 'usage: tools/wvm_kernel.sh LINUX_SOURCE OUTPUT_DIR [JOBS]' >&2
    exit 2
fi
source_dir=$(realpath "$1")
mkdir -p "$2"
output_dir=$(realpath "$2")
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
jobs=${3:-4}
make -C "$source_dir" O="$output_dir" x86_64_defconfig
(cd "$source_dir" && scripts/kconfig/merge_config.sh -m -O "$output_dir" "$output_dir/.config" "$script_dir/wvm_kernel.config")
make -C "$source_dir" O="$output_dir" olddefconfig
# Dependencies can silently demote requested settings; reject that outcome.
while IFS= read -r setting; do
    case "$setting" in CONFIG_*=y)
        if ! grep -qxF "$setting" "$output_dir/.config"; then
            echo "missing required built-in: $setting" >&2
            exit 1
        fi ;;
    esac
done < "$script_dir/wvm_kernel.config"
make -C "$source_dir" O="$output_dir" -j "$jobs" bzImage
sha256sum "$output_dir/arch/x86/boot/bzImage" "$output_dir/.config" > "$output_dir/wvm-kernel.sha256"
