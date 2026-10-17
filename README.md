# mooly

A device-tuned CachyOS-derived Linux kernel package.

`mooly` is built for a specific laptop configuration: AMD Ryzen 5 5600H with Radeon graphics, NVIDIA GeForce GTX 1650, NVMe storage, and Btrfs. It combines CachyOS kernel optimizations with additional memory, responsiveness, OC/OV, and hardware-specific tuning.

## Highlights

- BORE CPU scheduler
- Native Zen 3 compiler optimization
- Clang Thin LTO
- 1000 Hz timer frequency
- Full tickless operation
- Full preemption
- Performance CPU governor by default
- ZFS support
- NVIDIA open module support
- Integrated `ryzen_smu` module for AMD OC/OV access
- Memory-optimized kernel configuration
- Responsiveness-focused boot parameters
- Device-specific module trimming with `localmodconfig`

## Package contents

- `linux-mooly` — kernel and modules
- `linux-mooly-headers` — headers for out-of-tree modules
- `linux-mooly-zfs` — ZFS module
- `linux-mooly-nvidia-open` — NVIDIA open module
- `linux-mooly-ryzen-smu` — AMD Ryzen SMU module

## Quick install

One-line install:

```bash
curl -fsSL https://raw.githubusercontent.com/mochibunr/mooly/main/install.sh | bash
```

With tuning:

```bash
curl -fsSL https://raw.githubusercontent.com/mochibunr/mooly/main/install.sh | bash -s -- --tune
```

Clone and install manually:

```bash
git clone https://github.com/mochibunr/mooly.git
cd mooly
./install.sh
```

Build from source instead of using prebuilt packages:

```bash
./install.sh --build
```

## What the installer does

By default, `install.sh` downloads the latest prebuilt packages from GitHub Releases and installs them with `pacman`.

With `--build`, it:

1. Installs build dependencies
2. Generates a `modprobed.db` from currently loaded modules
3. Aligns the NVIDIA module version with installed `nvidia-utils`
4. Builds the kernel with `makepkg`
5. Installs the resulting packages

## Kernel tuning included

- `mitigations=off`
- `processor.max_cstate=1`
- `cpufreq.default_governor=performance`
- `amd_pstate=active`
- `threadirqs`
- `preempt=full`
- `tsc=reliable`
- `clocksource=tsc`
- `skew_tick=1`
- `rcu_nocbs=all`
- `transparent_hugepage=madvise`
- `init_on_alloc=0`
- `init_on_free=0`
- `slub_debug=-`
- `amdgpu.ppfeaturemask=0xffffffff`

## Memory optimizations

The kernel configuration disables or reduces several heavy debug and tracing features, including:

- Debug info
- BTF debug info
- kallsyms
- ftrace/function tracer
- SLUB debug
- default init-on-alloc/free zeroing

It also enables `CONFIG_CC_OPTIMIZE_FOR_SIZE`.

## Important notes

- This kernel is heavily tailored to the author's hardware.
- `localmodconfig` means modules not loaded during the build may be omitted.
- If you use different hardware, regenerate:

  ```bash
  mkdir -p ~/.local/share/modprobed-db
  lsmod | awk 'NR > 1 { print $1 }' > ~/.local/share/modprobed-db/modprobed.db
  ```

- NVIDIA support depends on a matching `nvidia-utils` version. The installer handles this automatically.
- Raising power or clock limits can increase heat and power consumption. Use with care.

## Verification after boot

```bash
uname -r
modinfo ryzen_smu
ls /sys/kernel/ryzen_smu_drv
modinfo nvidia
```

## License

See `LICENSE`.