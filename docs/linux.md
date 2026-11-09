# EoWRecomp on Linux (x86-64, aarch64)

Status: Linux / Vulkan on x86-64 is where the game runs furthest (the opening and the first controllable scene,
`docs/STATUS.md`), so far tested on an Intel Iris Xe (Mesa ANV). No Linux release has been published yet: `make
appimage` builds one, and `make smoketest` is the check to run on it before a release. aarch64 is **experimental**:
cross-compiled, untested on real hardware.

## Running the AppImage
    chmod +x EoWRecomp-<version>-linux-x86_64.AppImage
    ./EoWRecomp-<version>-linux-x86_64.AppImage

Needs: a distribution with glibc 2.35 or newer (Ubuntu 22.04, Debian 12, Fedora 36, Arch, SteamOS 3, ...), a Vulkan
1.3 driver (Mesa RADV / ANV / NVK / Turnip / Asahi Honeykrisp, or NVIDIA's), and on x86-64 a CPU with AVX2 (2013 or
newer). The start screen asks for the folder with your own `.nsp` / `.xci` and `prod.keys`, and builds the game code
from them on your machine (the AppImage carries the generator and the compiler, no game code).

Everything the app writes lives in `~/.local/share/eowrecomp` (`$XDG_DATA_HOME/eowrecomp`): the game code, saves,
settings (`eowrecomp.ini`), shader caches, imported fonts. Started without a terminal the log is
`~/.local/share/eowrecomp/eowrecomp.log` (from a terminal it prints there instead). `EOWRECOMP_DATA_ROOT=<dir>` uses
another folder.

Controllers work through SDL3's gamepad support (bundled): Xbox, PlayStation (DualShock 4, DualSense), Switch Pro /
Joy-Con, 8BitDo and other pads through the kernel's drivers, plugged in or paired while the game runs. For SDL's own
drivers (rumble, LEDs and gyro on PlayStation / Switch pads) the user needs access to `/dev/hidraw*`, which most
distributions give with Steam's udev rules (`steam-devices`, or Steam installed); without them the controller still
works through the kernel driver. Started from Steam with Steam Input on, the game sees Steam's virtual Xbox controller
(Xbox prompts).

If the AppImage won't start with a FUSE error, install your distribution's `fuse3` package (the AppImage runtime
needs `fusermount3`), or run it with `--appimage-extract-and-run`.

## Steam Deck
**Not tested yet** - reports welcome (see "What to report" below). The Deck is an x86-64 Linux machine with an AMD
GPU (Mesa RADV), so it takes the x86-64 AppImage as it is; what is new there is the GPU driver: so far the game has
only run on Intel (ANV). The renderer already uses D32S8 depth on AMD (no D24S8 attachments there,
`runtime/nvn/vulkan/textures.c`) and decodes ASTC textures on the CPU (`runtime/nvn/astc.c`).

1. In desktop mode, put the AppImage somewhere in your home folder (for example `~/Applications`) and run it once
   from the file manager or Konsole: set the game up from your own files on the start screen (building the game code
   takes a while on the Deck).
2. Steam -> Games -> Add a Non-Steam Game -> the AppImage. Game Mode runs it under Gamescope, fullscreen.
3. With Steam Input on (the default) the Deck's controls are an Xbox controller to the game.

The Deck's screen is 1280x800 (16:10): the default aspect ratio (unlocked) uses all of it.

## Building from source
Ubuntu / Debian packages (other distributions: the same libraries under their names; SDL3 3.2 or newer):

    sudo apt install clang lld make pkg-config python3-venv libsdl3-dev libavformat-dev libavcodec-dev \
        libavutil-dev libswscale-dev libvulkan-dev libshaderc-dev libvulkan-memory-allocator-dev glslc vulkan-tools

Or without installing anything system-wide: `tools/linux/dev_deps.sh` (zig as the compiler and the -dev packages
fetched into `build/`, see `docs/STATUS.md`). Then from the repo root:

    python3 -m venv tools/venv && tools/venv/bin/pip install lz4 capstone unicorn cryptography pillow
    make -j         # the start screen only (no game code yet): set up the game files there, or put extracted/ here
    make gen        # once: recompile the game from your own game files
    make -j         # -> build/eowrecomp and the game code library build/eowgame.so

Run `./build/eowrecomp` from the repo root: with `extracted/` in the starting folder it uses that folder for
everything (dev mode) instead of `~/.local/share/eowrecomp`.

`ARCH` picks the target, separately from the OS: the generated code differs per arch (aarch64 runs the guest's
FP/SIMD as inline asm, like Apple Silicon; x86-64 lowers it to C with `-march=x86-64-v3`, like Windows). `make gen`
passes the matching `--simd`. A cross build (`ARCH=aarch64` on an x86-64 machine, `SYSROOT=<arm64 root filesystem>`)
keeps its own `generated-aarch64/` and `build/aarch64/`. Distributions that name shaderc's library
`libshaderc_shared.so` need `SHADERC=-lshaderc_shared`.

## AppImages
Needs podman, and for aarch64 QEMU user emulation with binfmt (`sudo apt install podman qemu-user qemu-user-binfmt`).

    make appimage                # this machine's arch -> build/dist/EoWRecomp-<version>-linux-<arch>.AppImage
    make appimage ARCH=aarch64   # cross-compiled from x86-64
    make appimages               # both

Everything is built in Ubuntu 22.04 containers (`tools/linux/Containerfile`), so the result runs on glibc 2.35+:
SDL3, an LGPL-only FFmpeg (only the movie codecs, as on macOS) and shaderc from pinned sources
(`tools/linux/build_deps.sh`), then the app against them (`tools/linux/package.sh`). aarch64 is cross-compiled in the
amd64 container against the arm64 image's root filesystem (`build/linux/aarch64/sysroot`). The game code generator
helper (`make gen-helper`, PyInstaller) is frozen in a container of its own arch (`build/linux/<arch>/helper`); on
arm64 that runs under QEMU.

The AppImage holds `eowrecomp`, what the start screen builds the game code with (`eowgen/`, `zig/`, `gamelib-src/`),
the start screen font and the bundled libraries (SDL3, FFmpeg, shaderc). Not bundled: glibc, libstdc++, the Vulkan
loader and the GPU drivers (always the system's). No game code, game files or fonts: `package.sh` stops if the app
has game code linked in.

### Release check
`make smoketest` (`tools/linux/smoketest.sh`) checks the x86-64 AppImage on this machine in three launches of the
AppImage itself: setup from this checkout's `extracted/` (game code built with the bundled generator and compiler);
the start screen; and a new game straight in - the opening, then the first controllable scene with scripted input.
Each step is checked in the log and by a screenshot; the report names the GPU and gives the frame rate in the first
scene. `build/smoke/report.txt` ends with READY FOR RELEASE or NOT READY; `build/smoke/sheet.png` shows every
screenshot. It needs `extracted/` in the checkout (`tools/nca_extract.py`, from your own files). Run it on the machine
you want to check - a Steam Deck in desktop mode works too (clone the repository there, put the AppImage in
`build/dist/` and your `extracted/` in the checkout; the script needs only bash and Python with Pillow).

## Differences from macOS / Windows
- Platform layer `runtime/platform/linux.c`: like macOS, the guest window (0x70_0000_0000..0x73_2000_0000) is one
  read/write mapping (`MAP_NORESERVE`), crashes are caught with `sigaction` on an alternate stack.
- The HLE / service / reset tables are ELF sections found through the linker's `__start_` / `__stop_` symbols.
- Renderer: the Vulkan backend shared with Windows and Android.
- Without the user's Switch fonts the game text uses DejaVu Sans (TrueType; the game's font engine can't use CFF
  fonts such as Noto Sans CJK).
- Pages: 4K and 16K kernels (Asahi) work; 64K-page kernels (some ARM servers) are not supported.

## What to report (Steam Deck, aarch64, any GPU not tested yet)
1. **Distribution and kernel**: `cat /etc/os-release | head -3; uname -r; getconf PAGESIZE`
2. **GPU and Vulkan driver**: `vulkaninfo --summary` (package `vulkan-tools`; on SteamOS it is installed); at least
   the devices section with `deviceName`, `driverName` and `driverInfo`.
3. **What happened**: start screen? setup? in game? where it stopped, any visual problems (screenshots help), the
   frame rate (the log's `[vk] ... fps` lines). With a controller: its model, and whether it works (the log names it:
   `[input] gamepad: ...`).
4. **The log**: `~/.local/share/eowrecomp/eowrecomp.log` (or the terminal output when started from a terminal).
   A crash writes `*** signal ...` and a backtrace there; attach the whole file. `make smoketest`'s
   `build/smoke/report.txt` and `sheet.png` help too.
5. **A crash backtrace with gdb** when the log's isn't enough:

       ./EoWRecomp-<version>-linux-<arch>.AppImage --appimage-extract    # -> squashfs-root/
       cd ~/.local/share/eowrecomp
       gdb -batch -ex 'handle SIGSEGV nostop noprint pass' -ex run -ex 'thread apply all bt 20' \
           --args ~/squashfs-root/usr/bin/eowrecomp > gdb.txt 2>&1

   (Adjust the `squashfs-root` path to where you extracted it. The game itself uses SIGSEGV for memory watches, hence
   the `handle` line; a real crash still ends in the backtrace. Attach `gdb.txt`.)
