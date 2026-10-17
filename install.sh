#!/usr/bin/env bash
#
# Installer for the linux-mooly kernel.
#
# Default mode downloads prebuilt packages from GitHub Releases.
# Use --build to compile from source instead.
#
# Usage:
#   ./install.sh [--build] [--tune] [--jobs N] [--repo URL] [--workdir DIR]
#
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/mochibunr/mooly.git}"
BRANCH="${BRANCH:-main}"
WORKDIR="${WORKDIR:-$HOME/src/mooly}"
JOBS="${JOBS:-$(nproc)}"
APPLY_TUNING=0
BUILD_FROM_SOURCE=0

usage() {
	cat <<EOF
Usage: $0 [options]

Options:
  --build           Build from source instead of downloading prebuilt packages.
  --tune            Apply optional CPU/GPU/system tuning.
  --jobs N          Parallel make jobs for source builds (default: $(nproc)).
  --repo URL        Git repository URL to clone.
  --workdir DIR     Where to clone/build (default: $HOME/src/mooly).
  --branch NAME     Git branch to clone (default: main).
  -h, --help        Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--build)
		BUILD_FROM_SOURCE=1
		shift
		;;
	--tune)
		APPLY_TUNING=1
		shift
		;;
	--jobs)
		JOBS="$2"
		shift 2
		;;
	--repo)
		REPO_URL="$2"
		shift 2
		;;
	--workdir)
		WORKDIR="$2"
		shift 2
		;;
	--branch)
		BRANCH="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
	exit 1
}

[[ $EUID -eq 0 ]] && die "Do not run this installer as root."
command -v pacman >/dev/null 2>&1 || die "This installer targets Arch/CachyOS (pacman not found)."
command -v sudo >/dev/null 2>&1 || die "sudo is required."
command -v curl >/dev/null 2>&1 || die "curl is required."

OWNER_REPO="mochibunr/mooly"

install_prebuilt() {
	local tmpdir tag assets nvidia_ver selected=()
	tmpdir="$(mktemp -d)"
	trap 'rm -rf "$tmpdir"' EXIT

	log "Querying latest GitHub release"
	local release_json
	release_json="$(curl -fsSL "https://api.github.com/repos/${OWNER_REPO}/releases/latest")" ||
		die "Could not query GitHub releases."

	tag="$(printf '%s' "$release_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])')"
	assets="$(printf '%s' "$release_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("\n".join(a["name"] for a in d.get("assets",[]) if a["name"].endswith(".pkg.tar.zst"))))')"

	[[ -n "$assets" ]] || die "No package assets found in release $tag."

	log "Downloading prebuilt packages from release $tag"
	while IFS= read -r asset; do
		[[ -n "$asset" ]] || continue
		log "  $asset"
		curl -fL --progress-bar -o "$tmpdir/$asset" \
			"https://github.com/${OWNER_REPO}/releases/download/${tag}/${asset}" ||
			die "Failed to download $asset"
	done <<<"$assets"

	# Optional checksum verification
	if curl -fsSL "https://github.com/${OWNER_REPO}/releases/download/${tag}/SHA256SUMS" -o "$tmpdir/SHA256SUMS" 2>/dev/null; then
		log "Verifying checksums"
		(cd "$tmpdir" && sha256sum -c SHA256SUMS) || die "Checksum verification failed."
	else
		warn "SHA256SUMS not found in release; skipping checksum verification."
	fi

	# Skip NVIDIA package if nvidia-utils version does not match
	if pacman -Q nvidia-utils >/dev/null 2>&1; then
		nvidia_ver="$(pacman -Q nvidia-utils | awk '{print $2}' | cut -d- -f1)"
	else
		nvidia_ver=""
	fi

	for pkg in "$tmpdir"/*.pkg.tar.zst; do
		base="$(basename "$pkg")"
		if [[ "$base" == linux-mooly-nvidia-open-* ]]; then
			if [[ -z "$nvidia_ver" ]]; then
				warn "Skipping $base (nvidia-utils not installed)."
				continue
			fi
			if [[ "$base" != *"$nvidia_ver"* ]]; then
				warn "Skipping $base (installed nvidia-utils is $nvidia_ver)."
				continue
			fi
		fi
		selected+=("$pkg")
	done

	[[ ${#selected[@]} -gt 0 ]] || die "No compatible packages to install."

	log "Installing prebuilt packages"
	sudo pacman -U --noconfirm "${selected[@]}"
}

build_from_source() {
	if [[ -f "PKGBUILD" && -f "config" ]]; then
		SRC_DIR="$(pwd)"
		log "Using existing source tree in $SRC_DIR"
	else
		if [[ -d "$WORKDIR/.git" ]]; then
			log "Updating existing clone in $WORKDIR"
			git -C "$WORKDIR" pull --ff-only
		else
			log "Cloning $REPO_URL into $WORKDIR"
			rm -rf "$WORKDIR"
			git clone --branch "$BRANCH" "$REPO_URL" "$WORKDIR"
		fi
		SRC_DIR="$WORKDIR"
		[[ -f "$SRC_DIR/PKGBUILD" ]] || die "PKGBUILD not found in $SRC_DIR"
	fi

	cd "$SRC_DIR"

	log "Installing build dependencies"
	sudo pacman -S --needed --noconfirm base-devel git rust rust-bindgen rust-src

	MODPROBED_DB="$HOME/.local/share/modprobed-db/modprobed.db"
	mkdir -p "$(dirname "$MODPROBED_DB")"
	if [[ ! -s "$MODPROBED_DB" ]]; then
		log "Generating modprobed.db from currently loaded modules"
		if command -v modprobed-db >/dev/null 2>&1; then
			modprobed-db store || true
		fi
		if [[ ! -s "$MODPROBED_DB" ]]; then
			lsmod | awk 'NR > 1 { print $1 }' >"$MODPROBED_DB"
		fi
	fi
	[[ -s "$MODPROBED_DB" ]] || warn "modprobed.db is empty; localmodconfig may trim too much."

	if pacman -Q nvidia-utils >/dev/null 2>&1; then
		NV_VER="$(pacman -Q nvidia-utils | awk '{print $2}' | cut -d- -f1)"
		if grep -q '^_nv_ver=' PKGBUILD; then
			CURRENT_NV_VER="$(sed -n 's/^_nv_ver=//p' PKGBUILD)"
			if [[ "$CURRENT_NV_VER" != "$NV_VER" ]]; then
				log "Aligning NVIDIA module version: $CURRENT_NV_VER -> $NV_VER"
				sed -i "s/^_nv_ver=.*/_nv_ver=$NV_VER/" PKGBUILD
			fi
		fi
	else
		warn "nvidia-utils is not installed; disabling NVIDIA open module build."
		sed -i 's/: "${_build_nvidia_open:=yes}"/: "${_build_nvidia_open:=no}"/' PKGBUILD
	fi

	log "Building linux-mooly (this can take a while)"
	MAKEFLAGS="-j${JOBS} -l${JOBS}" makepkg -si --noconfirm
}

apply_tuning() {
	log "Applying optional tuning"

	sudo tee /etc/systemd/system/cpu-minfreq.service >/dev/null <<'EOF'
[Unit]
Description=Set CPU minimum frequency to half of maximum
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq); min=$((max / 2)); /usr/bin/cpupower frequency-set -d "$min"'

[Install]
WantedBy=multi-user.target
EOF
	sudo systemctl daemon-reload
	sudo systemctl enable --now cpu-minfreq.service || true

	if command -v nvidia-smi >/dev/null 2>&1; then
		sudo tee /etc/systemd/system/nvidia-minclock.service >/dev/null <<'EOF'
[Unit]
Description=Lock NVIDIA GPU minimum clock to half of maximum
After=systemd-modules-load.service nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStart=/usr/bin/nvidia-smi -lgc 892,1785

[Install]
WantedBy=multi-user.target
EOF
		sudo systemctl daemon-reload
		sudo systemctl enable nvidia-minclock.service || true
		sudo nvidia-smi -pm 1 >/dev/null 2>&1 || true
		sudo nvidia-smi -lgc 892,1785 >/dev/null 2>&1 || true
	fi

	sudo tee /etc/sysctl.d/99-background-efficiency.conf >/dev/null <<'EOF'
vm.swappiness=180
vm.page-cluster=0
vm.vfs_cache_pressure=50
kernel.sched_autogroup_enabled=1
EOF
	sudo sysctl --load=/etc/sysctl.d/99-background-efficiency.conf >/dev/null || true

	if [[ -f /etc/makepkg.conf ]]; then
		sudo sed -i 's/BUILDENV=(!distcc color !ccache check !sign)/BUILDENV=(!distcc color ccache check !sign)/' /etc/makepkg.conf || true
		sudo sed -i 's|^MAKEFLAGS="-j\$(nproc)"|MAKEFLAGS="-j$(nproc) -l$(nproc)"|' /etc/makepkg.conf || true
	fi

	log "Tuning applied"
}

if [[ $BUILD_FROM_SOURCE -eq 1 ]]; then
	build_from_source
elif ! (install_prebuilt); then
	warn "Prebuilt packages are unavailable; falling back to a source build."
	build_from_source
fi

configure_boot() {
    log "Configuring bootloader"

    if command -v mkinitcpio >/dev/null 2>&1; then
        sudo mkinitcpio -P >/dev/null 2>&1 || warn "mkinitcpio -P reported errors; continuing."
    fi

    if command -v limine-snapper-sync >/dev/null 2>&1; then
        sudo limine-snapper-sync || warn "limine-snapper-sync failed; update Limine manually."
    elif command -v limine-update >/dev/null 2>&1; then
        sudo limine-update || warn "limine-update failed; update Limine manually."
    elif command -v grub-mkconfig >/dev/null 2>&1 && [[ -f /boot/grub/grub.cfg ]]; then
        sudo grub-mkconfig -o /boot/grub/grub.cfg || warn "grub-mkconfig failed; update GRUB manually."
    elif command -v bootctl >/dev/null 2>&1; then
        sudo bootctl update || warn "bootctl update failed; update systemd-boot manually."
    elif command -v refind-install >/dev/null 2>&1; then
        sudo refind-install || warn "refind-install failed; update rEFInd manually."
    else
        warn "No supported bootloader updater found. Update your boot configuration manually."
    fi
}

configure_boot

if [[ $APPLY_TUNING -eq 1 ]]; then
	apply_tuning
fi

log "Installation complete."
log "Reboot and select the 'linux-mooly' boot entry."
log "Verify after boot with: uname -r && modinfo ryzen_smu && ls /sys/kernel/ryzen_smu_drv"
