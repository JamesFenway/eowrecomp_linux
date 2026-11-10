#!/bin/bash
# make appimage ARCH=<x86_64|aarch64>: build/dist/EoWRecomp-<version>-linux-<arch>.AppImage, built in Ubuntu 22.04
# containers (podman; tools/linux/Containerfile) so it runs on glibc 2.35+ distributions. Everything is built inside
# the amd64 container - aarch64 cross-compiled against the arm64 image's root filesystem (build/linux/aarch64/sysroot)
# - except the game code generator helper (make gen-helper), which PyInstaller only freezes in a container of its own
# arch (arm64: QEMU, binfmt).
# No game code inside: the start screen builds it on the player's machine. See docs/linux.md.
set -euo pipefail
cd "$(dirname "$0")/../.."
ARCH=${1:?usage: tools/linux/appimage.sh x86_64|aarch64}
case $ARCH in x86_64) PODARCH=amd64 ;; aarch64) PODARCH=arm64 ;;
    *) echo "unknown arch $ARCH"; exit 1 ;; esac

image() {  # arch -> tag (built once, then cached by podman)
    # (exit: set -e does not reach into the $(image ...) subshell, and a failed build would go on to a missing image)
    podman build -q --arch "$1" -t "localhost/eowrecomp-build:$1" -f tools/linux/Containerfile tools/linux >/dev/null || exit 1
    echo "localhost/eowrecomp-build:$1"
}
run() {  # image, command...: the checkout mounted at /src
    local img=$1; shift
    podman run --rm --arch "${img##*:}" -v "$PWD:/src" -w /src -e SYSROOT=/src/build/linux/aarch64/sysroot -e GAMEOPT="${GAMEOPT:--O1}" "$img" "$@"
}

AMD=$(image amd64)
if [ "$ARCH" = aarch64 ]; then
    ARM=$(image arm64)
    S=build/linux/aarch64/sysroot
    if [ ! -f "$S/.ok" ]; then  # the arm64 image's files: headers and libraries to cross-compile against
        rm -rf "$S" && mkdir -p "$S"
        c=$(podman create --arch arm64 "$ARM")
        # (anchored: only the top-level pseudo filesystems, not e.g. usr/include/<triple>/sys)
        podman export "$c" | tar -x -C "$S" --anchored --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' 2>/dev/null || true
        podman rm -f "$c" >/dev/null
        # absolute symlinks (libm.so -> /lib/aarch64-linux-gnu/libm.so.6) would point into this machine's root:
        # relative, so they stay inside the sysroot
        find "$S" -type l -lname '/*' | while read -r l; do
            ln -sfn "$(realpath -m --relative-to="$(dirname "$l")" "$S$(readlink "$l")")" "$l"
        done
        touch "$S/.ok"
    fi
fi
# the generator helper -> build/linux/<arch>/helper/eowgen (package.sh ships it: the start screen runs it to build the
# game code from the player's files); its venv on the image's Python 3.12, one per arch
helper() {  # image
    run "$1" make gen-helper GEN_PY=python3.12 GEN_VENV="build/linux/$ARCH/gen-venv" \
        GEN_HELPER_DIR="build/linux/$ARCH/helper" GEN_HELPER_WORK="build/linux/$ARCH/pyinstaller"
}
if [ "$ARCH" = aarch64 ]; then helper "$ARM"; else helper "$AMD"; fi
run "$AMD" tools/linux/package.sh "$ARCH"
