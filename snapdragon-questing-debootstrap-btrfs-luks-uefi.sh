#!/usr/bin/env bash
# snapdragon-questing-debootstrap-btrfs-luks-uefi.sh
# v.38
#
# Deterministic(ish) manual Ubuntu 25.10 “Questing” install via debootstrap + chroot,
# from a booted Ubuntu ISO environment, targeting ARM64 and ports.ubuntu.com.
#
# Methodology inspired by Silvenga’s guide (with significant changes per your spec):
# https://silvenga.com/posts/bypassing-the-installer-manually-installing-ubuntu/
#
# NON-DESTRUCTIVE WARNING:
# - This script WILL create TWO NEW partitions in *selected free space* on a chosen disk.
# - It will NOT wipe existing partitions, labels, or EFI entries.
#
# v29 changes (vs v14):
# - Reworked free-space detection to parse `parted -m ... print free` robustly, including GPT "free" rows
#   expressed in either sectors ("s") or MiB ("MiB"). Avoids awk reserved-word pitfalls.
# - Presents *all* detected free regions, echoes the underlying `parted print free` output, picks the largest by size,
#   and requires explicit confirmation before partition creation.
# - Removed any dependency on `numfmt` (it is part of coreutils anyway; do not apt-install it).
#
set -Eeuo pipefail

### ------------------------------ FLAGS ----------------------------------- ###
ENFORCE_CUSTOM_KERNEL=1

usage() {
  cat <<'EOF'
Usage: sudo bash questing-debootstrap-btrfs-luks-uefi-v38.sh [options]

Options:
  --enforce-custom-kernel       Enforce custom kernel only (default: ON)
  --no-enforce-custom-kernel    Do not purge/pin/hold kernels (default: OFF)
  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enforce-custom-kernel) ENFORCE_CUSTOM_KERNEL=1; shift ;;
    --no-enforce-custom-kernel) ENFORCE_CUSTOM_KERNEL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

### ------------------------------ CONFIG ---------------------------------- ###
RELEASE="questing"
ARCH="arm64"
MIRROR="http://ports.ubuntu.com/ubuntu-ports"

# Snapdragon boot files bundle (DTBs + GRUB menu template)
SNAPDRAGON_BOOTFILES_ZIP_URL="https://github.com/JeremiahCornelius/snapdragon_boot_files/archive/refs/heads/master.zip"

TARGET_MNT="/srv/target"
BUILD_DIR_REL="/opt/var/build"
REPO_DIR_REL="/opt/var/repository"
BUILD_LOG_TMP="/tmp/questing-debootstrap-install.log"

BOOT_SIZE_MIB=500
BOOT_LABEL="BOOT"
ROOT_LABEL="UBUNTU"

BTRFS_OPTS="defaults,noatime,space_cache=v2,compress=zstd"
ESP_VFAT_OPTS="rw,noatime,fmask=0022,dmask=0022,codepage=437,iocharset=utf8,shortname=mixed,errors=remount-ro"

BTRFS_SUBVOLS=(
  "@"
  "@snapshots"
  "@home"
  "@root"
  "@var@log"
  "@var@lib@AccountsService"
  "@var@lib@gdm3"
  "@tmp"
  "@swap"
  "@home/.snapshots"
  "@var@lib@docker"
)

SWAPFILE_SIZE_GIB=8
SWAPFILE_NAME="swapfile"

EXTRA_KERNEL_CMDLINE_TOKENS=( pd_ignore_unused clk_ignore_unused regulator_ignore_unused )

GDRIVE_DEBS=(
  "linux-buildinfo-6.19.0-rc8-jg-1-qcom-x1e_6.19.0-rc8-jg-1_arm64.deb|https://drive.google.com/uc?id=1gi_1Qypl8hLMQWMb6z-YxYPwIuu4344d"
  "linux-headers-6.19.0-rc8-jg-1-qcom-x1e_6.19.0-rc8-jg-1_arm64.deb|https://drive.google.com/uc?id=1yegCpqowHOIQFkCD0CChuTfTitz31Rt7"
  "linux-image-6.19.0-rc8-jg-1-qcom-x1e_6.19.0-rc8-jg-1_arm64.deb|https://drive.google.com/uc?id=1hcZP5Ga-SWUjNDJGq0p5Y6-vi6nudSKO"
  "linux-modules-6.19.0-rc8-jg-1-qcom-x1e_6.19.0-rc8-jg-1_arm64.deb|https://drive.google.com/uc?id=1gdL1kLHfYH376ijVcWKLjlfuqldVWrlB"
  "linux-qcom-x1e-headers-6.19.0-rc8-jg-1_6.19.0-rc8-jg-1_all.deb|https://drive.google.com/uc?id=1kTOIXNFpwiETksIWHXkZcv8vx6A3XhwR"
  "linux-qcom-x1e-tools-6.19.0-rc8-jg-1_6.19.0-rc8-jg-1_arm64.deb|https://drive.google.com/uc?id=1bjJbXV2l9SFINDZsm2o4VRUOdB8vDc1C"
  "linux-tools-6.19.0-rc8-jg-1-qcom-x1e_6.19.0-rc8-jg-1_arm64.deb|https://drive.google.com/uc?id=1FIVsFtVF_ygua72dYwH-0AgsNZNZxtvR"
)

BASE_META_PKGS=( ubuntu-minimal ubuntu-standard )

DESKTOP_PKGS=(
  ubuntu-desktop
  ubuntu-session
  vanilla-gnome-desktop
  vanilla-gnome-default-settings
)

EXTRA_PKGS=(
  build-essential
  btrfs-progs
  cryptsetup
  cryptsetup-initramfs
  initramfs-tools
  locales
  tzdata
  sudo
  ca-certificates
  gnupg
  grub-efi-arm64
  efibootmgr
  os-prober
  shim-signed
  systemd-sysv
  network-manager
  openssh-client
)

PLATFORM_REPO_PKGS=(
  stubble
  flash-kernel
  ubuntu-x1e-settings
  ubuntu-x1e-settings-nogrub
  qcom-firmware-extract
  dislocker
  ntfs-3g
)

USER_GROUPS=( lp cdrom floppy sudo audio dip video plugdev netdev bluetooth lpadmin scanner gnome-remote-desktop )

CUSTOM_KERNEL_PKGS=(
  "linux-buildinfo-6.19.0-rc8-jg-1-qcom-x1e"
  "linux-headers-6.19.0-rc8-jg-1-qcom-x1e"
  "linux-image-6.19.0-rc8-jg-1-qcom-x1e"
  "linux-modules-6.19.0-rc8-jg-1-qcom-x1e"
  "linux-qcom-x1e-headers-6.19.0-rc8-jg-1"
  "linux-qcom-x1e-tools-6.19.0-rc8-jg-1"
  "linux-tools-6.19.0-rc8-jg-1-qcom-x1e"
)

INITRAMFS_FORCE_MODULES=(
  "dm-crypt"
  "dm-mod"
  "cryptd"
  "sha256_generic"
  "aes_generic"
  "btrfs"
)

### ------------------------------ STATE ----------------------------------- ###
STEPS_DONE=()
CURRENT_STEP="(starting)"
CRYPT_NAME=""
DISK=""
BOOT_PART=""
ROOT_PART=""
ESP_PART=""
ESP_UUID=""
BOOT_UUID=""
BTRFS_UUID=""
LUKS_UUID=""
HOSTNAME=""
USERNAME=""
REALNAME=""
USERPASS=""
LUKSPASS=""
TZ="America/Los_Angeles"
LOCALE="en_US.UTF-8"

PARTS_BEFORE=()
PARTS_AFTER=()
NEW_PARTS=()

FREE_START_MIB=""
FREE_END_MIB=""
FREE_SIZE_MIB=""

ISO_DISK_EXCLUDE=""

### ------------------------------ LOGGING --------------------------------- ###
log() { local msg="$*"; echo "[$(date -Is)] $msg" | tee -a "$BUILD_LOG_TMP" >&2; }
step() { CURRENT_STEP="$1"; log "==> $CURRENT_STEP"; STEPS_DONE+=("$CURRENT_STEP"); }

fail_summary() {
  echo
  echo "❌ Installation failed."
  echo "Failure at step: $CURRENT_STEP"
  echo
  echo "Steps completed:"
  for s in "${STEPS_DONE[@]}"; do echo "  - $s"; done
  echo
  echo "Log (ISO environment): $BUILD_LOG_TMP"
  echo
}

### ------------------------------ CLEANUP --------------------------------- ###
unmount_all() {
  log "==> (cleanup) Unmount target mounts and close LUKS mapping (best-effort)"
  swapoff "$TARGET_MNT/swap/$SWAPFILE_NAME" >/dev/null 2>&1 || true
  for m in     "$TARGET_MNT/boot/efi" "$TARGET_MNT/boot" "$TARGET_MNT/swap" "$TARGET_MNT/tmp"     "$TARGET_MNT/var/lib/docker" "$TARGET_MNT/var/lib/gdm3" "$TARGET_MNT/var/lib/AccountsService"     "$TARGET_MNT/var/log" "$TARGET_MNT/root" "$TARGET_MNT/home/.snapshots" "$TARGET_MNT/home"     "$TARGET_MNT/.snapshots" "$TARGET_MNT/dev/pts" "$TARGET_MNT/dev" "$TARGET_MNT/proc"     "$TARGET_MNT/sys" "$TARGET_MNT" ; do
    umount -R "$m" >/dev/null 2>&1 || true
  done
  [[ -n "${CRYPT_NAME:-}" ]] && cryptsetup close "$CRYPT_NAME" >/dev/null 2>&1 || true
}

on_err() { local ec=$?; fail_summary; unmount_all || true; exit "$ec"; }
trap on_err ERR

### ------------------------------ HELPERS --------------------------------- ###
require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }; }
require_uefi() { [[ -d /sys/firmware/efi ]] || { echo "UEFI not detected." >&2; exit 1; }; }

pause_confirm() {
  local prompt="$1" ans=""
  while true; do
    read -r -p "$prompt [y/N]: " ans || true
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

read_nonempty() {
  local varname="$1" prompt="$2" default="${3:-}" val=""
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " val || true
      val="${val:-$default}"
    else
      read -r -p "$prompt: " val || true
    fi
    [[ -n "$val" ]] || { echo "Value cannot be empty."; continue; }
    printf -v "$varname" "%s" "$val"
    return 0
  done
}

read_password_confirm_loop() {
  local varname="$1" label="$2" p1="" p2=""
  while true; do
    read -r -s -p "$label: " p1 || true; echo
    read -r -s -p "$label (confirm): " p2 || true; echo
    if [[ -n "$p1" && "$p1" == "$p2" ]]; then
      printf -v "$varname" "%s" "$p1"
      return 0
    fi
    echo "Passwords did not match (or empty). Please try again."
  done
}

apt_host_install_if_missing() {
  local pkgs=("$@") missing=()
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if (( ${#missing[@]} > 0 )); then
    log "Installing missing host tools: ${missing[*]}"
    apt update -y
    apt install -y "${missing[@]}"
  fi
}

disable_host_cdrom_sources_and_prefer_ports() {
  step "Disable host CD-ROM APT sources and prefer ports.ubuntu.com"
  [[ -f /etc/apt/sources.list ]] && {
    sed -i -E 's|^[[:space:]]*deb[[:space:]]+cdrom:|# deb cdrom:|g' /etc/apt/sources.list || true
    sed -i -E 's|^[[:space:]]*deb[[:space:]]+file:|# deb file:|g' /etc/apt/sources.list || true
  }
  if [[ -d /etc/apt/sources.list.d ]]; then
    while IFS= read -r -d '' f; do
      sed -i -E 's|^[[:space:]]*deb[[:space:]]+cdrom:|# deb cdrom:|g' "$f" || true
      sed -i -E 's|^[[:space:]]*deb[[:space:]]+file:|# deb file:|g' "$f" || true
    done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f -name "*.list" -print0 2>/dev/null || true)
  fi
  [[ -s /etc/apt/sources.list ]] || cat >/etc/apt/sources.list <<EOF
deb ${MIRROR} ${RELEASE} main restricted universe multiverse
deb ${MIRROR} ${RELEASE}-updates main restricted universe multiverse
deb ${MIRROR} ${RELEASE}-security main restricted universe multiverse
EOF
  apt update -y || true
}

refresh_block_devices() {
  step "Refresh block device enumeration (nvme probe + udev settle)"
  modprobe nvme >/dev/null 2>&1 || true
  udevadm settle || true
  partprobe >/dev/null 2>&1 || true
  udevadm settle || true
}

detect_cdrom_backing_disk() {
  if mountpoint -q /cdrom; then
    local src pk
    src="$(findmnt -n -o SOURCE /cdrom 2>/dev/null || true)"
    pk="$(lsblk -no PKNAME "$src" 2>/dev/null || true)"
    if [[ -n "$pk" ]]; then ISO_DISK_EXCLUDE="/dev/$pk"; fi
  fi
  [[ -n "$ISO_DISK_EXCLUDE" ]] && log "Detected /cdrom backing disk (excluded from targets): $ISO_DISK_EXCLUDE"
}

list_disks_lsblk_candidates() {
  lsblk -d -p -n -o NAME,SIZE,MODEL,RM,RO,TYPE 2>/dev/null     | awk '$6=="disk"{print $1"\t"$2"\t"$3"\t"$4"\t"$5}'     | while IFS=$'\t' read -r name size model rm ro; do
        [[ -n "$name" ]] || continue
        [[ "$name" == "$ISO_DISK_EXCLUDE" ]] && continue
        [[ "$name" =~ /dev/loop|/dev/ram ]] && continue
        [[ "${ro:-1}" == "0" ]] || continue
        echo -e "$name\t$size\t${model:-}\t${rm:-}\t${ro:-}"
      done
}

list_disks_sysfs_fallback() {
  while IFS= read -r -d '' dev; do
    local base ro rm model sz512 bytes gib path
    base="$(basename "$dev")"
    [[ "$base" =~ ^loop|^ram ]] && continue
    ro="$(cat "/sys/block/$base/ro" 2>/dev/null || echo 1)"
    rm="$(cat "/sys/block/$base/removable" 2>/dev/null || echo 1)"
    model="$(tr -d '\0' < "/sys/block/$base/device/model" 2>/dev/null | xargs || true)"
    sz512="$(cat "/sys/block/$base/size" 2>/dev/null || echo 0)"
    bytes=$(( sz512 * 512 ))
    gib=$(( bytes / 1024 / 1024 / 1024 ))
    [[ "$ro" == "0" ]] || continue
    path="/dev/$base"
    [[ "$path" == "$ISO_DISK_EXCLUDE" ]] && continue
    echo -e "$path\t${gib}GB\t${model:-}\t${rm:-}\t${ro:-}"
  done < <(find /sys/block -maxdepth 1 -mindepth 1 -type l -printf '%p\0' 2>/dev/null)
}

choose_disk() {
  step "Select target disk (non-destructive)"
  refresh_block_devices
  detect_cdrom_backing_disk

  local disks_lsblk; disks_lsblk="$(list_disks_lsblk_candidates || true)"

  echo
  echo "Available target disks (excluding ISO /cdrom disk when detected):"
  if [[ -n "$disks_lsblk" ]]; then
    mapfile -t DISK_LINES < <(echo "$disks_lsblk")
    local i=0
    for line in "${DISK_LINES[@]}"; do
      i=$((i+1))
      echo "  [$i] $(echo "$line" | awk -F'\t' '{print $1"  size="$2"  model=\"" $3 "\"  rm="$4"  ro="$5}')"
    done
  else
    echo "  (none detected via lsblk)"
    echo
    echo "Sysfs fallback scan:"
    mapfile -t SYSFS_LINES < <(list_disks_sysfs_fallback || true)
    if (( ${#SYSFS_LINES[@]} > 0 )); then
      local j=0
      for line in "${SYSFS_LINES[@]}"; do
        j=$((j+1))
        echo "  [$j] $(echo "$line" | awk -F'\t' '{print $1"  size="$2"  model=\"" $3 "\"  rm="$4"  ro="$5}')"
      done
      DISK_LINES=("${SYSFS_LINES[@]}")
    else
      DISK_LINES=()
    fi
  fi

  echo
  echo "Tip: you can always enter a device manually (e.g. /dev/nvme0n1)."
  echo

  local choice=""
  while true; do
    read -r -p "Choose disk number or enter full device path: " choice || true
    if [[ "$choice" =~ ^/dev/ ]]; then
      [[ -b "$choice" ]] || { echo "Not a block device: $choice"; continue; }
      DISK="$choice"; break
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DISK_LINES[@]} )); then
      DISK="$(echo "${DISK_LINES[$((choice-1))]}" | awk -F'\t' '{print $1}')"
      break
    fi
    echo "Invalid selection."
  done

  [[ -b "$DISK" ]] || { echo "Selected disk not present: $DISK" >&2; exit 1; }
  log "Selected disk: $DISK"
}

disk_geometry() {
  local disk="$1" ss spm
  ss="$(blockdev --getss "$disk" 2>/dev/null || echo 512)"
  spm=$(( (1024*1024) / ss ))
  echo "$ss $spm"
}

to_mib_number() {
  local token="$1" spm="$2"
  if [[ "$token" =~ MiB$ ]]; then
    local n="${token%MiB}"; n="${n%%.*}"; [[ -n "$n" ]] || n=0; echo "$n"
  elif [[ "$token" =~ s$ ]]; then
    local s="${token%s}"; [[ "$s" =~ ^[0-9]+$ ]] || s=0; echo $(( s / spm ))
  else
    local n="${token%%[^0-9.]*}"; n="${n%%.*}"; [[ -n "$n" ]] || n=0; echo "$n"
  fi
}

choose_free_region() {
  step "Scan for largest free space region (parted -m print free)"
  local ss spm; read -r ss spm < <(disk_geometry "$DISK")
  log "Disk sector size=$ss bytes, sectors_per_MiB=$spm"

  local pm="/tmp/parted-machine.$$.txt"
  parted -m -s "$DISK" unit s print free >"$pm"

  local regions=()
  while IFS= read -r line; do
    [[ "$line" == BYT* ]] && continue
    [[ "$line" == "$DISK:"* ]] && continue
    [[ "$line" != *:* ]] && continue
    line="${line%;}"
    local num start end size fs name flags
    IFS=':' read -r num start end size fs name flags <<<"$line"
    [[ "${fs:-}" == "free" ]] || continue
    local s_mib e_mib z_mib
    s_mib="$(to_mib_number "$start" "$spm")"
    e_mib="$(to_mib_number "$end" "$spm")"
    z_mib="$(to_mib_number "$size" "$spm")"
    (( z_mib > 0 )) || z_mib=$(( e_mib > s_mib ? e_mib - s_mib : 0 ))
    regions+=( "${s_mib}\t${e_mib}\t${z_mib}\t${start}\t${end}\t${size}" )
  done <"$pm"

  if (( ${#regions[@]} == 0 )); then
    log "WARN: parted succeeded but no free-space rows parsed from machine output."
    log "parted -m output (first 50 lines):"
    head -n 50 "$pm" | while IFS= read -r l; do log "$l"; done
    echo; echo "ERROR: No free space regions detected on $DISK using parted." >&2
    echo; echo "parted (human) print free:"; parted "$DISK" unit MiB print free || true
    exit 1
  fi

  IFS=$'\n' regions_sorted=($(printf "%b\n" "${regions[@]}" | sort -t$'\t' -k3,3nr)); unset IFS

  echo
  echo "Free space regions on $DISK (MiB) [parsed from parted -m unit s print free]:"
  local idx=0
  for r in "${regions_sorted[@]}"; do
    idx=$((idx+1))
    echo "  [$idx] start=$(echo -e "$r" | awk -F'\t' '{print $1}')MiB  end=$(echo -e "$r" | awk -F'\t' '{print $2}')MiB  size=$(echo -e "$r" | awk -F'\t' '{print $3}')MiB   (raw: $(echo -e "$r" | awk -F'\t' '{print $4".." $5 ", size=" $6}'))"
  done
  echo
  echo "parted (human) print free (for your verification):"
  parted "$DISK" unit MiB print free | sed -n '1,120p'
  echo

  local choice="" selected=""
  while true; do
    read -r -p "Choose a free region number to use (largest is [1]): " choice || true
    choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Enter a number."; continue; }
    if (( choice >= 1 && choice <= ${#regions_sorted[@]} )); then
      selected="${regions_sorted[$((choice-1))]}"; break
    fi
    echo "Invalid selection."
  done

  FREE_START_MIB="$(echo -e "$selected" | awk -F'\t' '{print $1}')"
  FREE_END_MIB="$(echo -e "$selected" | awk -F'\t' '{print $2}')"
  FREE_SIZE_MIB="$(echo -e "$selected" | awk -F'\t' '{print $3}')"

  (( FREE_SIZE_MIB >= BOOT_SIZE_MIB + 2048 )) || { echo "Selected region too small." >&2; exit 1; }

  echo
  echo "Selected free region: ${FREE_START_MIB}MiB -> ${FREE_END_MIB}MiB (size ${FREE_SIZE_MIB}MiB)"
  echo "Will create:"
  echo "  - ${BOOT_SIZE_MIB}MiB ext4 partition labeled ${BOOT_LABEL}"
  echo "  - Remaining space btrfs partition labeled ${ROOT_LABEL} (then LUKS1 on top)"
  echo
  pause_confirm "Proceed to create NEW partitions inside the selected free region on ${DISK}?" || { echo "Aborted by user."; exit 0; }
}

snapshot_partitions() { local disk="$1"; lsblk -rpn -o NAME,TYPE "$disk" | awk '$2=="part"{print $1}' | sort -u; }

create_partitions_non_destructive() {
  step "Create BOOT and UBUNTU partitions (non-destructive within free space)"
  mapfile -t PARTS_BEFORE < <(snapshot_partitions "$DISK")
  log "Partitions before: ${PARTS_BEFORE[*]:-(none)}"

  local boot_start="${FREE_START_MIB}MiB"
  local boot_end="$((FREE_START_MIB + BOOT_SIZE_MIB))MiB"
  local root_start="$((FREE_START_MIB + BOOT_SIZE_MIB))MiB"
  local root_end="${FREE_END_MIB}MiB"

  log "Partition plan on $DISK:"
  log "  BOOT: $boot_start -> $boot_end"
  log "  ROOT: $root_start -> $root_end"

  parted --script --align optimal "$DISK"     mkpart primary ext4 "$boot_start" "$boot_end"     mkpart primary btrfs "$root_start" "$root_end"

  partprobe "$DISK" || true
  udevadm settle || true

  mapfile -t PARTS_AFTER < <(snapshot_partitions "$DISK")
  log "Partitions after: ${PARTS_AFTER[*]:-(none)}"

  NEW_PARTS=()
  for p in "${PARTS_AFTER[@]}"; do
    local seen=0
    for b in "${PARTS_BEFORE[@]}"; do [[ "$p" == "$b" ]] && { seen=1; break; }; done
    (( seen == 0 )) && NEW_PARTS+=("$p")
  done

  if (( ${#NEW_PARTS[@]} != 2 )); then
    echo "ERROR: Expected exactly 2 new partitions, found ${#NEW_PARTS[@]}: ${NEW_PARTS[*]:-(none)}" >&2
    exit 1
  fi
  log "New partitions detected: ${NEW_PARTS[*]}"
}

format_and_label_partitions() {
  step "Format BOOT (ext4) and ROOT (LUKS1 -> btrfs) partitions"
  local p1="${NEW_PARTS[0]}" p2="${NEW_PARTS[1]}"
  local s1 s2; s1="$(blockdev --getsize64 "$p1")"; s2="$(blockdev --getsize64 "$p2")"
  if (( s1 <= s2 )); then BOOT_PART="$p1"; ROOT_PART="$p2"; else BOOT_PART="$p2"; ROOT_PART="$p1"; fi
  log "New BOOT_PART=$BOOT_PART (smaller), ROOT_PART=$ROOT_PART (larger)"

  mkfs.ext4 -F -L "$BOOT_LABEL" "$BOOT_PART"

  echo -n "$LUKSPASS" | cryptsetup luksFormat --type luks1 --batch-mode "$ROOT_PART" -
  LUKS_UUID="$(cryptsetup luksUUID "$ROOT_PART")"
  CRYPT_NAME="luks-${LUKS_UUID}"

  echo -n "$LUKSPASS" | cryptsetup open "$ROOT_PART" "$CRYPT_NAME" -
  mkfs.btrfs -f -L "$ROOT_LABEL" "/dev/mapper/$CRYPT_NAME"

  BOOT_UUID="$(blkid -s UUID -o value "$BOOT_PART")"
  BTRFS_UUID="$(blkid -s UUID -o value "/dev/mapper/$CRYPT_NAME")"
  log "BOOT_UUID=$BOOT_UUID"
  log "BTRFS_UUID=$BTRFS_UUID"
  log "LUKS_UUID=$LUKS_UUID"
}

mount_for_subvol_create() {
  step "Mount raw BTRFS and create subvolumes"
  mkdir -p /mnt/rootfs-tmp
  mount "/dev/mapper/$CRYPT_NAME" /mnt/rootfs-tmp
  for sv in "${BTRFS_SUBVOLS[@]}"; do btrfs subvolume create "/mnt/rootfs-tmp/$sv" >/dev/null; done
  umount /mnt/rootfs-tmp
  rmdir /mnt/rootfs-tmp || true
}

mount_target_layout() {
  step "Mount target layout at /srv/target (BTRFS subvols + BOOT)"
  mkdir -p "$TARGET_MNT"
  mount -o "subvol=@,${BTRFS_OPTS}" "/dev/mapper/$CRYPT_NAME" "$TARGET_MNT"

  mkdir -p "$TARGET_MNT"/{boot,boot/efi,home,root,var/log,var/lib/AccountsService,var/lib/gdm3,var/lib/docker,tmp,swap}
  mkdir -p "$TARGET_MNT/.snapshots" "$TARGET_MNT/home/.snapshots"

  mount -o "subvol=@snapshots,${BTRFS_OPTS}" "/dev/mapper/$CRYPT_NAME" "$TARGET_MNT/.snapshots"
  mount -o "subvol=@home,${BTRFS_OPTS}" "/dev/mapper/$CRYPT_NAME" "$TARGET_MNT/home"
  mount -o "subvol=@home/.snapshots,${BTRFS_OPTS}" "/dev/mapper/$CRYPT_NAME" "$TARGET_MNT/home/.snapshots"
  mount -o "subvol=@root,${BTRFS_OPTS}" "/dev/mapper/$CRYPT_NAME" "$TARGET_MNT/root"
  mount -o "subvol=@var@log,${BTRFS_OPTS}" "/dev/mapper/$CRYPT_NAME" "$TARGET_MNT/var/log"
  mount -o "subvol=@var@lib@AccountsService,${BTRFS_OPTS}" "/dev/mapper/$CRYPT_NAME" "$TARGET_MNT/var/lib/AccountsService"
  mount -o "subvol=@var@lib@gdm3,${BTRFS_OPTS}" "/dev/mapper/$CRYPT_NAME" "$TARGET_MNT/var/lib/gdm3"
  mount -o "subvol=@var@lib@docker,${BTRFS_OPTS}" "/dev/mapper/$CRYPT_NAME" "$TARGET_MNT/var/lib/docker"
  mount -o "subvol=@tmp,${BTRFS_OPTS}" "/dev/mapper/$CRYPT_NAME" "$TARGET_MNT/tmp"
  mount -o "subvol=@swap,${BTRFS_OPTS}" "/dev/mapper/$CRYPT_NAME" "$TARGET_MNT/swap"

  mount "$BOOT_PART" "$TARGET_MNT/boot"
}

find_and_mount_esp() {
  step "Locate existing EFI System Partition (ESP) and mount it at /srv/target/boot/efi"
  local cand=()
  while IFS= read -r line; do cand+=("$line"); done < <(lsblk -rpn -o NAME,FSTYPE,PARTTYPE,PARTFLAGS,SIZE | awk '$2=="vfat"{print $0}')
  (( ${#cand[@]} > 0 )) || { echo "No VFAT partitions found; cannot locate ESP." >&2; exit 1; }

  echo; echo "Candidate ESP partitions:"
  local i=0; for c in "${cand[@]}"; do i=$((i+1)); echo "  [$i] $c"; done; echo

  local choice=""
  while true; do
    read -r -p "Choose ESP number: " choice || true
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Enter a number."; continue; }
    if (( choice >= 1 && choice <= ${#cand[@]} )); then ESP_PART="$(echo "${cand[$((choice-1))]}" | awk '{print $1}')"; break; fi
    echo "Invalid selection."
  done

  ESP_UUID="$(blkid -s UUID -o value "$ESP_PART" || true)"
  mkdir -p "$TARGET_MNT/boot/efi"
  mount "$ESP_PART" "$TARGET_MNT/boot/efi"
  log "Selected ESP: $ESP_PART (UUID=$ESP_UUID)"
}

setup_swapfile_btrfs() {
  step "Create swapfile inside @swap subvolume (no CoW), enable now"
  local swapfile_path="$TARGET_MNT/swap/$SWAPFILE_NAME"
  truncate -s 0 "$swapfile_path"
  chattr +C "$swapfile_path" || true
  dd if=/dev/zero of="$swapfile_path" bs=1M count=$((SWAPFILE_SIZE_GIB * 1024)) status=progress
  chmod 600 "$swapfile_path"
  mkswap "$swapfile_path"
  swapon "$swapfile_path" || true
}

write_apt_sources_target() {
  step "Write target APT sources (ports.ubuntu.com)"
  cat >"$TARGET_MNT/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${RELEASE} main restricted universe multiverse
deb ${MIRROR} ${RELEASE}-updates main restricted universe multiverse
deb ${MIRROR} ${RELEASE}-security main restricted universe multiverse
EOF
}

debootstrap_base() { step "Debootstrap base system"; debootstrap --arch="$ARCH" --variant=minbase --include=apt,ubuntu-keyring,ca-certificates,gpgv "$RELEASE" "$TARGET_MNT" "$MIRROR"; }

mount_kernel_interfaces() {
  step "Bind-mount kernel interfaces into target (dev, proc, sys, pts)"
  mkdir -p "$TARGET_MNT/dev" "$TARGET_MNT/dev/pts" "$TARGET_MNT/proc" "$TARGET_MNT/sys"

  mountpoint -q "$TARGET_MNT/dev"     || mount --bind /dev "$TARGET_MNT/dev"
  mountpoint -q "$TARGET_MNT/dev/pts" || mount -t devpts devpts "$TARGET_MNT/dev/pts"
  mountpoint -q "$TARGET_MNT/proc"    || mount -t proc proc "$TARGET_MNT/proc"
  mountpoint -q "$TARGET_MNT/sys"     || mount -t sysfs sysfs "$TARGET_MNT/sys"
}

chroot_cmd() {
  # IMPORTANT:
  # We intentionally use plain chroot here (not arch-chroot) because we already
  # mount /dev, /proc, and /sys into the target. arch-chroot attempts to mount
  # these again and can fail with "already mounted or mount point busy" on some
  # live ISO environments.
  chroot "$TARGET_MNT" /usr/bin/env bash -lc "$*"
}

install_arch_install_scripts_host() { step "Ensure arch-install-scripts available on ISO host"; apt_host_install_if_missing arch-install-scripts; }

generate_fstab_and_crypttab() {
  step "Generate /etc/fstab and /etc/crypttab"
  mkdir -p "$TARGET_MNT/$BUILD_DIR_REL"
  genfstab -U "$TARGET_MNT" >"$TARGET_MNT/$BUILD_DIR_REL/genfstab.raw" || true
  local luks_part_uuid; luks_part_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
  cat >"$TARGET_MNT/etc/crypttab" <<EOF
${CRYPT_NAME} UUID=${luks_part_uuid} none luks,discard
EOF
  cat >"$TARGET_MNT/etc/fstab" <<EOF
UUID=${ESP_UUID} /boot/efi vfat ${ESP_VFAT_OPTS} 0 2
UUID=${BOOT_UUID} /boot ext4 defaults,noatime 0 2
UUID=${BTRFS_UUID} / btrfs subvol=/@,${BTRFS_OPTS} 0 0
UUID=${BTRFS_UUID} /.snapshots btrfs subvol=/@snapshots,${BTRFS_OPTS} 0 0
UUID=${BTRFS_UUID} /home btrfs subvol=/@home,${BTRFS_OPTS} 0 0
UUID=${BTRFS_UUID} /home/.snapshots btrfs subvol=/@home/.snapshots,${BTRFS_OPTS} 0 0
UUID=${BTRFS_UUID} /root btrfs subvol=/@root,${BTRFS_OPTS} 0 0
UUID=${BTRFS_UUID} /var/log btrfs subvol=/@var@log,${BTRFS_OPTS} 0 0
UUID=${BTRFS_UUID} /var/lib/AccountsService btrfs subvol=/@var@lib@AccountsService,${BTRFS_OPTS} 0 0
UUID=${BTRFS_UUID} /var/lib/gdm3 btrfs subvol=/@var@lib@gdm3,${BTRFS_OPTS} 0 0
UUID=${BTRFS_UUID} /var/lib/docker btrfs subvol=/@var@lib@docker,${BTRFS_OPTS} 0 0
UUID=${BTRFS_UUID} /tmp btrfs subvol=/@tmp,${BTRFS_OPTS} 0 0
UUID=${BTRFS_UUID} /swap btrfs subvol=/@swap,${BTRFS_OPTS} 0 0
/swap/${SWAPFILE_NAME} none swap defaults 0 0
EOF
}

configure_target_basic_files() {
  step "Write hostname + hosts (target)"
  echo "$HOSTNAME" >"$TARGET_MNT/etc/hostname"
  cat >"$TARGET_MNT/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
}


sync_host_apt_extras_into_target() {
  step "Sync host ISO APT extras into target (PPAs, keyrings) if present"

  # Some customized ISO builds carry additional PPAs and keyrings that must be present
  # inside the target before the first apt update, otherwise package selection and
  # signature verification behavior may differ between host and target.
  mkdir -p "$TARGET_MNT/etc/apt/sources.list.d" "$TARGET_MNT/etc/apt/trusted.gpg.d" "$TARGET_MNT/usr/share/keyrings" "$TARGET_MNT/etc/apt/apt.conf.d"

  # Copy extra lists/sources if present on host
  if compgen -G "/etc/apt/sources.list.d/*.list" >/dev/null 2>&1; then
    cp -a /etc/apt/sources.list.d/*.list "$TARGET_MNT/etc/apt/sources.list.d/" 2>/dev/null || true
  fi
  if compgen -G "/etc/apt/sources.list.d/*.sources" >/dev/null 2>&1; then
    cp -a /etc/apt/sources.list.d/*.sources "$TARGET_MNT/etc/apt/sources.list.d/" 2>/dev/null || true
  fi

  # Copy trusted keyrings / keyring files if present
  if compgen -G "/etc/apt/trusted.gpg.d/*.gpg" >/dev/null 2>&1; then
    cp -a /etc/apt/trusted.gpg.d/*.gpg "$TARGET_MNT/etc/apt/trusted.gpg.d/" 2>/dev/null || true
  fi
  if compgen -G "/usr/share/keyrings/*.gpg" >/dev/null 2>&1; then
    cp -a /usr/share/keyrings/*.gpg "$TARGET_MNT/usr/share/keyrings/" 2>/dev/null || true
  fi

  # If the host ISO includes a prebuilt "extra-ppas" pair, copy it explicitly too.
  if [[ -f /etc/apt/sources.list.d/extra-ppas.list ]]; then
    cp -a /etc/apt/sources.list.d/extra-ppas.list "$TARGET_MNT/etc/apt/sources.list.d/" 2>/dev/null || true
  fi
  if [[ -f /etc/apt/trusted.gpg.d/extra-ppas.key.chroot.gpg ]]; then
    cp -a /etc/apt/trusted.gpg.d/extra-ppas.key.chroot.gpg "$TARGET_MNT/etc/apt/trusted.gpg.d/" 2>/dev/null || true
  fi

  # Ensure apt can run in a minimal chroot environment by disabling the _apt sandbox
  # (common pitfall: apt-secure calls gpgv as sandbox user and fails in some chroots).
  cat >"$TARGET_MNT/etc/apt/apt.conf.d/99sandbox-root" <<'EOF'
APT::Sandbox::User "root";
EOF
}

ensure_target_apt_signature_tools() {
  step "Ensure target can verify APT signatures (gpgv + keyring + sandbox config)"

  # gpgv is the verifier used by apt-secure. It must be present *and executable* in target.
  if ! chroot_cmd "command -v gpgv >/dev/null 2>&1"; then
    echo "ERROR: gpgv not present in target. (It should have been included by debootstrap --include=gpgv.)" >&2
    exit 1
  fi

  # Ensure Ubuntu archive keyring is present (package name differs across releases; file is stable).
  if ! chroot_cmd "test -s /usr/share/keyrings/ubuntu-archive-keyring.gpg"; then
    log "WARN: ubuntu-archive-keyring.gpg not found in target; attempting to install ubuntu-keyring (may require apt update)."
    chroot_cmd "DEBIAN_FRONTEND=noninteractive apt -o APT::Sandbox::User=root update -y" || true
    chroot_cmd "DEBIAN_FRONTEND=noninteractive apt -o APT::Sandbox::User=root install -y ubuntu-keyring" || true
  fi

  # Final sanity check: execute gpgv inside target.
  chroot_cmd "gpgv --version >/dev/null 2>&1"
  log "Target gpgv execution check: OK"
}

install_packages_in_chroot() {
  step "Install packages inside target"

  # Copy any ISO-provided PPAs/keyrings into the target before first apt update.
  sync_host_apt_extras_into_target

  # Ensure signature verification prerequisites exist and are executable.
  ensure_target_apt_signature_tools

  # First update/upgrade pass (also validates that signed repositories work).
  chroot_cmd "DEBIAN_FRONTEND=noninteractive apt -o APT::Sandbox::User=root update -y"
  chroot_cmd "DEBIAN_FRONTEND=noninteractive apt -o APT::Sandbox::User=root upgrade -y" || true

  # Install base + desktop sets.
  chroot_cmd "DEBIAN_FRONTEND=noninteractive apt -o APT::Sandbox::User=root install -y ${BASE_META_PKGS[*]}"
  chroot_cmd "DEBIAN_FRONTEND=noninteractive apt -o APT::Sandbox::User=root install -y ${DESKTOP_PKGS[*]} ${EXTRA_PKGS[*]}"

  # Best-effort: also install suggested packages for the desktop set (non-fatal).
  local suggests=""
  suggests="$(chroot_cmd "apt -s -o APT::Sandbox::User=root install ${DESKTOP_PKGS[*]} ${EXTRA_PKGS[*]} \
    | awk '
      BEGIN{ins=0}
      /^Suggested packages:/{ins=1; sub(/^Suggested packages:[[:space:]]*/,\"\", \$0); print; next}
      ins==1 && /^[[:space:]]/{gsub(/^[[:space:]]+/,\"\", \$0); print; next}
      ins==1 && !/^[[:space:]]/{exit}
    ' \
    | tr \"\n\" \" \" | sed 's/[()<>]//g' | sed 's/|/ /g' | tr -s \" \" | xargs -r echo" || true)"

  if [[ -n "${suggests:-}" ]]; then
    log "Installing suggested packages (desktop set): $suggests"
    chroot_cmd "DEBIAN_FRONTEND=noninteractive apt -o APT::Sandbox::User=root install -y $suggests" || true
  fi
}


configure_locale_timezone() {
  step "Configure locale + timezone"
  chroot_cmd "DEBIAN_FRONTEND=noninteractive apt install -y locales tzdata"
  chroot_cmd "locale-gen ${LOCALE} || true"
  chroot_cmd "update-locale LANG=${LOCALE} || true"
  chroot_cmd "ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime"
  chroot_cmd "dpkg-reconfigure -f noninteractive tzdata || true"
}

configure_network_manager_best_effort() {
  step "Configure NetworkManager"
  chroot_cmd "DEBIAN_FRONTEND=noninteractive apt install -y network-manager"
  chroot_cmd "systemctl enable NetworkManager.service || true"
}

install_gdown_on_host() {
  step "Install gdown in ISO environment"
  apt_host_install_if_missing python3 python3-pip || true
  if ! command -v gdown >/dev/null 2>&1; then
    apt install -y gdown >/dev/null 2>&1 || true
  fi
  if ! command -v gdown >/dev/null 2>&1; then
    python3 -m pip install --break-system-packages -U gdown || python3 -m pip install -U gdown || true
  fi
  command -v gdown >/dev/null 2>&1 || { echo "ERROR: gdown is required but not available on host." >&2; exit 1; }
}

download_debs_with_gdown_into_target() {
  step "Download Google Drive .debs into target repository"
  mkdir -p "$TARGET_MNT/$REPO_DIR_REL"
  for item in "${GDRIVE_DEBS[@]}"; do
    local fname="${item%%|*}" url="${item#*|}"
    log "gdown -> $fname"
    gdown --quiet --fuzzy -O "$TARGET_MNT/$REPO_DIR_REL/$fname" "$url"
    [[ -s "$TARGET_MNT/$REPO_DIR_REL/$fname" ]] || { echo "Downloaded file is empty: $fname" >&2; exit 1; }
  done
}

install_custom_kernel_and_tools_debs() {
  step "Install custom kernel .debs via apt"
  chroot_cmd "apt update -y"
  local deb_paths=()
  for item in "${GDRIVE_DEBS[@]}"; do deb_paths+=("$REPO_DIR_REL/${item%%|*}"); done
  chroot_cmd "DEBIAN_FRONTEND=noninteractive apt install -y ${deb_paths[*]}"
}

install_platform_repo_packages() { step "Install platform repo packages"; chroot_cmd "apt update -y"; chroot_cmd "DEBIAN_FRONTEND=noninteractive apt install -y ${PLATFORM_REPO_PKGS[*]}"; }

force_initramfs_modules() {
  step "Force-initramfs modules"
  local modfile="$TARGET_MNT/etc/initramfs-tools/modules"
  mkdir -p "$(dirname "$modfile")"; touch "$modfile"
  for m in "${INITRAMFS_FORCE_MODULES[@]}"; do grep -Eq "^[[:space:]]*${m}([[:space:]]|$)" "$modfile" && continue; echo "$m" >>"$modfile"; done
}

install_initramfs_iso_dtb_hook() {
  step "Install initramfs hook to embed Snapdragon DTBs (ONLY bundle DTBs) into initrd (best-effort)"

  # If present, this hook embeds the DTBs listed in /boot/dtb/.iso-dtbs.list into the initramfs.
  # This is a belt-and-suspenders measure: GRUB loads DTBs from /boot/dtb via 'devicetree',
  # but embedding also helps if a future boot path expects them inside initrd.

  local hook_dir="$TARGET_MNT/etc/initramfs-tools/hooks"
  mkdir -p "$hook_dir"

  cat >"$hook_dir/zz-snapdragon-dtbs" <<'EOF'
#!/bin/sh
set -e

PREREQ=""
prereqs() { echo "$PREREQ"; }

case "$1" in
  prereqs) prereqs; exit 0 ;;
esac

. /usr/share/initramfs-tools/hook-functions

MANIFEST="/boot/dtb/.iso-dtbs.list"
DTBDIR="/boot/dtb"

if [ ! -s "$MANIFEST" ]; then
  exit 0
fi

mkdir -p "${DESTDIR}/boot/dtb" || true

while IFS= read -r dtb; do
  [ -n "$dtb" ] || continue
  src="${DTBDIR}/${dtb}"
  if [ -f "$src" ]; then
    copy_file file "$src" "/boot/dtb/${dtb}"
  fi
done < "$MANIFEST"

exit 0
EOF

  chmod +x "$hook_dir/zz-snapdragon-dtbs"
}




update_initramfs_all_kernels() { step "Update initramfs for all kernels"; chroot_cmd "DEBIAN_FRONTEND=noninteractive apt install -y initramfs-tools"; chroot_cmd "update-initramfs -u -k all"; }

verify_crypttab_and_initramfs_has_luks_support() {
  step "Verify initramfs has LUKS support"
  chroot_cmd "test -s /etc/crypttab"
  chroot_cmd "command -v lsinitramfs >/dev/null 2>&1"
}

enforce_custom_kernel_only() {
  step "Enforce custom kernel only"
  chroot_cmd "DEBIAN_FRONTEND=noninteractive apt purge -y 'linux-generic*' 'linux-image-generic*' 'linux-headers-generic*' 'linux-image-arm64*' 'linux-headers-arm64*' 'linux-hwe-*' 'linux-meta*' || true"
  mkdir -p "$TARGET_MNT/etc/apt/preferences.d"
  cat >"$TARGET_MNT/etc/apt/preferences.d/99-custom-kernel.pref" <<EOF
Package: ${CUSTOM_KERNEL_PKGS[*]}
Pin: origin ""
Pin-Priority: 1001
EOF
  chroot_cmd "apt-mark hold ${CUSTOM_KERNEL_PKGS[*]} || true"
}


sync_dtbs_for_grub_menu() {
  step "Sync Snapdragon DTBs + GRUB DTB menu template from GitHub bundle (deterministic)"
  # The ISO runtime does NOT reliably expose the DTBs/kernel used at ISO-boot time.
  # Instead, we pull the authoritative DTB set (exactly 12) and the model GRUB config
  # from your GitHub bundle, then stage them into the target /boot/dtb and /boot/grub/custom.cfg.

  # Host tools
  apt_host_install_if_missing curl unzip

  local tmpd="/tmp/snapdragon_boot_files.$$"
  rm -rf "$tmpd" || true
  mkdir -p "$tmpd"

  log "Downloading Snapdragon boot bundle zip: $SNAPDRAGON_BOOTFILES_ZIP_URL"
  curl -fsSL -o "$tmpd/bundle.zip" "$SNAPDRAGON_BOOTFILES_ZIP_URL"

  # Unpack
  unzip -q "$tmpd/bundle.zip" -d "$tmpd/unz"
  local rootdir
  rootdir="$(find "$tmpd/unz" -maxdepth 1 -type d -name 'snapdragon_boot_files-*' | head -n1 || true)"
  [[ -n "${rootdir:-}" && -d "$rootdir" ]] || { echo "ERROR: Could not locate extracted bundle root directory." >&2; exit 1; }

  local src_dtb_dir="$rootdir/boot/dtb"
  local src_grub_dir="$rootdir/boot/grub"
  [[ -d "$src_dtb_dir" ]] || { echo "ERROR: DTB directory not found in bundle: $src_dtb_dir" >&2; exit 1; }
  [[ -d "$src_grub_dir" ]] || { echo "ERROR: GRUB directory not found in bundle: $src_grub_dir" >&2; exit 1; }

  local dtb_count
  dtb_count="$(find "$src_dtb_dir" -maxdepth 1 -type f -name '*.dtb' | wc -l | tr -d ' ')"
  (( dtb_count > 0 )) || { echo "ERROR: No DTB files found in bundle." >&2; exit 1; }

  # Create target dtb dir
  mkdir -p "$TARGET_MNT/boot/dtb"

  # Copy ONLY the DTBs from the bundle (no extras)
  log "Copying DTBs from bundle into target /boot/dtb (count=$dtb_count)"
  rm -f "$TARGET_MNT/boot/dtb/"*.dtb >/dev/null 2>&1 || true
  cp -f "$src_dtb_dir/"*.dtb "$TARGET_MNT/boot/dtb/"

  # Write a manifest used by the initramfs DTB hook (and for auditing)
  local manifest="$TARGET_MNT/boot/dtb/.iso-dtbs.list"
  : >"$manifest"
  (cd "$TARGET_MNT/boot/dtb" && ls -1 *.dtb | sort) >>"$manifest"
  log "DTB manifest written: /boot/dtb/.iso-dtbs.list"
  # Also write a TSV manifest used by grub.d generator: "<dtb_filename>	<label>"
  local manifest_tsv="$TARGET_MNT/boot/dtb/.iso-dtbs.tsv"
  : >"$manifest_tsv"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local base="${f%.dtb}"
    printf "%s	%s
" "$f" "$base" >>"$manifest_tsv"
  done < <(cd "$TARGET_MNT/boot/dtb" && ls -1 *.dtb 2>/dev/null | sort)
  log "DTB TSV manifest written: /boot/dtb/.iso-dtbs.tsv"

  # Install a DTB menu template as /boot/grub/custom.cfg (Ubuntu grub.cfg sources this automatically)
  local template_cfg=""
  if [[ -f "$src_grub_dir/custom.cfg" ]]; then
    template_cfg="$src_grub_dir/custom.cfg"
  elif [[ -f "$src_grub_dir/grub.cfg" ]]; then
    template_cfg="$src_grub_dir/grub.cfg"
  else
    # any single cfg file in that dir
    template_cfg="$(find "$src_grub_dir" -maxdepth 1 -type f -name '*.cfg' | head -n1 || true)"
  fi
  [[ -n "${template_cfg:-}" && -f "$template_cfg" ]] || { echo "ERROR: No GRUB cfg template found in bundle under $src_grub_dir" >&2; exit 1; }

  mkdir -p "$TARGET_MNT/boot/grub"
  cp -f "$template_cfg" "$TARGET_MNT/boot/grub/custom.cfg"

  # Patch the template for this install (UUIDs, crypt mapping, rootflags) while preserving labels/order.
  local luks_part_uuid btrfs_uuid
  luks_part_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
  btrfs_uuid="$BTRFS_UUID"

  # Normalize dtb pathing to /boot/dtb (the bundle expects dtb files there)
  sed -E -i \
    -e 's#devicetree[[:space:]]+/boot/dtb/#devicetree /dtb/#g' \
    -e 's#devicetree[[:space:]]+/boot/#devicetree /dtb/#g' \
    -e 's#devicetree[[:space:]]+/([^/[:space:]]+\.dtb)#devicetree /dtb/\1#g' \
    "$TARGET_MNT/boot/grub/custom.cfg" || true

  # Ensure cryptdevice uses the right UUID and mapping name (replace any existing cryptdevice=UUID=...:...)
  sed -i \
    -E "s#cryptdevice=UUID=[0-9a-fA-F-]+:[^[:space:]]+#cryptdevice=UUID=${luks_part_uuid}:${CRYPT_NAME}#g" \
    "$TARGET_MNT/boot/grub/custom.cfg" || true

  # Ensure root=UUID=... matches btrfs UUID (replace any existing root=UUID=...)
  sed -i \
    -E "s#root=UUID=[0-9a-fA-F-]+#root=UUID=${btrfs_uuid}#g" \
    "$TARGET_MNT/boot/grub/custom.cfg" || true

  # Ensure rootflags=subvol=@ present (append if missing on linux lines)
  if ! grep -qE 'rootflags=subvol=@' "$TARGET_MNT/boot/grub/custom.cfg"; then
    sed -i -E 's#(^[[:space:]]*linux[[:space:]].*)#\1 rootflags=subvol=@#' "$TARGET_MNT/boot/grub/custom.cfg" || true
  fi

  log "NOTE: Not installing bundle custom.cfg (it is ISO/casper-specific). DTB menu is generated via /etc/grub.d/09-iso-dtb."

  # Cleanup temp dir
  rm -rf "$tmpd" || true
}



install_iso_grub_dtb_and_windows_entries() {
  step "Install GRUB menu entries for ISO DTBs + Windows (deterministic)"
  # We avoid os-prober fragility on some firmware by providing a deterministic Windows chainloader entry,
  # and we provide DTB-specific Linux entries modeled after the ISO.
  #
  # Inputs:
  #   - /boot/dtb/.iso-dtbs.tsv   (created by sync_dtbs_for_grub_menu)
  #   - $ESP_UUID (selected ESP)
  #
  # Outputs:
  #   - /etc/grub.d/09-iso-dtb (DTB-specific Linux boot entries)
  #   - /etc/grub.d/12-windows-chainloader (Windows Boot Manager entry)
  #
  # Notes:
  # - Place DTB entries BEFORE 10_linux so GRUB_DEFAULT=0 boots a DTB entry by default.
  # - Use /vmlinuz and /initrd.img if present; otherwise fall back to latest vmlinuz-* / initrd.img-*.
  # - devicetree directive loads DTB from /boot (BOOT partition), not initramfs.
  # - Windows entry uses chainloader to Microsoft bootmgfw.efi on the ESP.

  local manifest="$TARGET_MNT/boot/dtb/.iso-dtbs.tsv"
  [[ -s "$manifest" ]] || { echo "ERROR: DTB manifest missing/empty: $manifest" >&2; exit 1; }

  local luks_part_uuid; luks_part_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
  [[ -n "${luks_part_uuid:-}" ]] || { echo "ERROR: Could not read UUID for LUKS partition: $ROOT_PART" >&2; exit 1; }

  mkdir -p "$TARGET_MNT/etc/default/grub.d"
  cat >"$TARGET_MNT/etc/default/grub.d/00-installer-ui.cfg" <<'EOF'
# Auto-generated
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=5
GRUB_DEFAULT=0
EOF

  # DTB-specific Linux entries (before 10_linux)
  cat >"$TARGET_MNT/etc/grub.d/09-iso-dtb" <<'EOF'
#!/usr/bin/env bash
set -e

# Auto-generated by questing-debootstrap-btrfs-luks-uefi-v38.sh
DTB_MANIFEST="/boot/dtb/.iso-dtbs.tsv"
BOOT_FS_UUID="__BOOT_UUID__"

# Source GRUB defaults so we inherit the same kernel command line as normal Ubuntu entries.
if [ -r /etc/default/grub ]; then
  . /etc/default/grub
fi
CMDLINE="${GRUB_CMDLINE_LINUX:-} ${GRUB_CMDLINE_LINUX_DEFAULT:-}"

# We are generating a GRUB menu that will boot from the separate /boot partition.
# So paths in menuentries must be relative to that filesystem root (search by BOOT_FS_UUID).
# Discover the newest installed kernel+initrd inside /boot *in the target filesystem*.
KERNEL="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort | tail -n 1 || true)"
INITRD_IMG="$(ls -1 /boot/initrd.img-* 2>/dev/null | sort | tail -n 1 || true)"

[ -n "$KERNEL" ] && [ -e "$KERNEL" ] || exit 0
[ -n "$INITRD_IMG" ] && [ -e "$INITRD_IMG" ] || exit 0

VMLINUX="/${KERNEL##*/}"
INITRD="/${INITRD_IMG##*/}"

[ -s "$DTB_MANIFEST" ] || exit 0

# Manifest format: <dtb_filename><TAB><menu_title>
while IFS=$'	' read -r dtb title; do
  dtb="${dtb//$'
'/}"
  title="${title//$'
'/}"
  [ -n "$dtb" ] || continue
  # DTBs live in /boot/dtb inside the target; at boot time they are on the /boot filesystem at /dtb/<file>
  [ -e "/boot/dtb/$dtb" ] || continue
  [ -n "$title" ] || title="$dtb"

  cat <<EOM
menuentry "$title" --class ubuntu --class gnu-linux --class gnu --class os {
  search --no-floppy --fs-uuid --set=root $BOOT_FS_UUID
  echo "Loading Linux ($VMLINUX) + DTB ($dtb) ..."
  devicetree /dtb/$dtb
  linux  $VMLINUX $CMDLINE
  initrd $INITRD
}
EOM
done < "$DTB_MANIFEST"
EOF
chmod +x "$TARGET_MNT/etc/grub.d/09-iso-dtb"
  sed -i "s/__BOOT_UUID__/${BOOT_UUID}/g" "$TARGET_MNT/etc/grub.d/09-iso-dtb"

  # Deterministic Windows UEFI chainloader entry (does NOT rely on os-prober).
  # We mount the existing ESP at /boot/efi; Windows bootmgfw.efi typically lives at /EFI/Microsoft/Boot/bootmgfw.efi.
  # This grub.d script uses GRUB variables (not bash) and must be written with a *single-quoted* heredoc to avoid host-shell expansion.
  cat >"$TARGET_MNT/etc/grub.d/25-windows-efi" <<'EOF'
#!/usr/bin/env sh
set -e

# Auto-generated by questing-debootstrap-btrfs-luks-uefi-v38.sh
# Deterministic Windows entry using ESP UUID + chainloader.
# If Windows is not present, this entry simply won't appear (search --fs-uuid fails).

ESP_UUID="__ESP_UUID__"
WIN_EFI_PATH="/EFI/Microsoft/Boot/bootmgfw.efi"

. /usr/share/grub/grub-mkconfig_lib

if [ -z "$ESP_UUID" ] || [ "$ESP_UUID" = "__ESP_UUID__" ]; then
  exit 0
fi

cat <<GRUB_EOF
menuentry 'Windows Boot Manager' --class windows --class os {
  insmod part_gpt
  insmod fat
  search --no-floppy --fs-uuid --set=root ${ESP_UUID}
  if [ -f (${root})${WIN_EFI_PATH} ]; then
    chainloader (${root})${WIN_EFI_PATH}
  else
    echo 'Windows EFI loader not found at: '${WIN_EFI_PATH}
    sleep 3
  fi
}
GRUB_EOF
EOF
  sed -i "s/__ESP_UUID__/${ESP_UUID}/g" "$TARGET_MNT/etc/grub.d/25-windows-efi"
  chmod +x "$TARGET_MNT/etc/grub.d/25-windows-efi"


  # Also enable os-prober (Ubuntu may default-disable it).
  mkdir -p "$TARGET_MNT/etc/default/grub.d"
  cat >"$TARGET_MNT/etc/default/grub.d/15-os-prober.cfg" <<'EOF'
GRUB_DISABLE_OS_PROBER=false
EOF


  # Deterministic Windows chainloader entry (after 10_linux is fine)
  cat >"$TARGET_MNT/etc/grub.d/12-windows-chainloader" <<EOF
#!/usr/bin/env bash
set -e

ESP_UUID="${ESP_UUID}"

# Only emit if the Microsoft bootloader exists on the ESP.
# grub-mkconfig runs with /boot/efi mounted; check the file path.
if [ -d /boot/efi/EFI/Microsoft/Boot ] && [ -f /boot/efi/EFI/Microsoft/Boot/bootmgfw.efi ]; then
cat <<MENU
menuentry 'Windows Boot Manager' {
  search --no-floppy --fs-uuid --set=root \$ESP_UUID
  chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
MENU
fi
EOF
  chmod +x "$TARGET_MNT/etc/grub.d/12-windows-chainloader"

  # Also enable os-prober (optional) to keep parity with typical Ubuntu dual-boot behavior.
  cat >"$TARGET_MNT/etc/default/grub.d/99-os-prober.cfg" <<'EOF'
# Auto-generated
GRUB_DISABLE_OS_PROBER=false
EOF
}



install_grub_uefi_in_chroot() {
  step "Install + configure GRUB2 (UEFI)"
  mountpoint -q "$TARGET_MNT/boot" || { echo "/boot is not mounted in target." >&2; exit 1; }
  mountpoint -q "$TARGET_MNT/boot/efi" || { echo "/boot/efi (ESP) is not mounted in target." >&2; exit 1; }

  # Ensure os-prober can add Windows entry (if present)
  chroot_cmd "DEBIAN_FRONTEND=noninteractive apt install -y grub-efi-arm64 efibootmgr os-prober"

  mkdir -p "$TARGET_MNT/etc/default/grub.d"

  # Enable os-prober and set a reasonable menu timeout (deterministic)
  cat >"$TARGET_MNT/etc/default/grub.d/10-deterministic-menu.cfg" <<'EOF'
# Auto-generated by questing-debootstrap-btrfs-luks-uefi-v38.sh
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_DISABLE_OS_PROBER=false
EOF

  # v29: grub.d snippet that:
  # - enables cryptodisk
  # - ensures cryptdevice/root/rootflags are present
  # - ensures extra ignore tokens are present (deduped)
  local luks_part_uuid; luks_part_uuid="$(blkid -s UUID -o value "$ROOT_PART")"

  cat >"$TARGET_MNT/etc/default/grub.d/99-luks-btrfs.cfg" <<EOF
# Auto-generated by questing-debootstrap-btrfs-luks-uefi-v38.sh
GRUB_ENABLE_CRYPTODISK=y

# Ensure baseline crypto/btrfs boot params are present
if ! echo " \${GRUB_CMDLINE_LINUX:-} " | grep -q " cryptdevice="; then
  GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:-} cryptdevice=UUID=${luks_part_uuid}:${CRYPT_NAME}"
fi

if ! echo " \${GRUB_CMDLINE_LINUX:-} " | grep -q " root=UUID=${BTRFS_UUID} "; then
  GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:-} root=UUID=${BTRFS_UUID}"
fi

if ! echo " \${GRUB_CMDLINE_LINUX:-} " | grep -q " rootflags=subvol=@ "; then
  GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:-} rootflags=subvol=@"
fi

# Ensure required ignore tokens are present (dedupe)
_required="pd_ignore_unused clk_ignore_unused regulator_ignore_unused"
for _w in \$_required; do
  case " \${GRUB_CMDLINE_LINUX:-} " in
    *" \${_w} "*) : ;;
    *) GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:-} \${_w}" ;;
  esac
done
EOF

  # Install to ESP using a stable bootloader-id folder name: EFI/Ubuntu
  chroot_cmd "grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=Ubuntu --recheck"

  # Also install a removable-media fallback (firmware may prefer fallback paths on some HP systems)
  chroot_cmd "grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=Ubuntu --removable --recheck" || true

  chroot_cmd "update-grub"
}


detect_system_vendor() {
  # Best-effort, returns lowercase string
  local v=""
  if command -v dmidecode >/dev/null 2>&1; then
    v="$(dmidecode -s system-manufacturer 2>/dev/null || true)"
  fi
  [[ -n "$v" ]] || v="$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || true)"
  echo "${v,,}"
}

esp_parent_disk() {
  # Given /dev/sda1 -> /dev/sda ; /dev/nvme0n1p1 -> /dev/nvme0n1 ; /dev/mmcblk0p1 -> /dev/mmcblk0
  local part="$1"
  if [[ "$part" =~ ^(/dev/nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"; return 0
  fi
  if [[ "$part" =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"; return 0
  fi
  if [[ "$part" =~ ^(/dev/[a-z]+)[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"; return 0
  fi
  # Fallback: ask lsblk
  local pk=""
  pk="$(lsblk -no PKNAME "$part" 2>/dev/null || true)"
  [[ -n "$pk" ]] && echo "/dev/$pk" || return 1
}

esp_part_number() {
  # Extract partition number for efibootmgr -p
  local part="$1"
  if [[ "$part" =~ p([0-9]+)$ ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
  if [[ "$part" =~ ([0-9]+)$ ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
  return 1
}

uefi_loader_path_on_esp() {
  # Prefer shim if present, else grub
  if [[ -f "$TARGET_MNT/boot/efi/EFI/Ubuntu/shimaa64.efi" ]]; then
    echo "\\EFI\\Ubuntu\\shimaa64.efi"; return 0
  fi
  if [[ -f "$TARGET_MNT/boot/efi/EFI/Ubuntu/grubaa64.efi" ]]; then
    echo "\\EFI\\Ubuntu\\grubaa64.efi"; return 0
  fi
  if [[ -f "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTAA64.EFI" ]]; then
    echo "\\EFI\\BOOT\\BOOTAA64.EFI"; return 0
  fi
  return 1
}

efibootmgr_get_bootnum_by_label() {
  local label="$1"
  efibootmgr 2>/dev/null | awk -v L="$label" '
    $0 ~ "^Boot[0-9A-Fa-f]{4}\\*" {
      line=$0
      sub(/^Boot/, "", line)
      bootnum=substr(line,1,4)
      sub(/^Boot[0-9A-Fa-f]{4}\\* /, "", $0)
      if ($0 == L) { print toupper(bootnum); exit 0 }
    }
  ' || true
}

efibootmgr_get_bootorder() {
  efibootmgr 2>/dev/null | awk -F'[: ]+' '/^BootOrder:/{print $2}' | tr -d '\r' || true
}

efibootmgr_set_bootorder_prefer() {
  # args: preferred_bootnum (4 hex), then any other bootnums to keep in current order
  local pref="$1"
  local cur; cur="$(efibootmgr_get_bootorder)"
  [[ -n "$cur" ]] || return 0

  IFS=, read -r -a cur_arr <<<"$cur"

  # Build new order: pref first (if exists), then keep others excluding pref duplicates
  local new_arr=()
  new_arr+=("$pref")
  for b in "${cur_arr[@]}"; do
    b="${b^^}"
    [[ "$b" == "$pref" ]] && continue
    new_arr+=("$b")
  done

  local joined; joined="$(IFS=,; echo "${new_arr[*]}")"
  log "Setting UEFI BootOrder to: $joined"
  efibootmgr -o "$joined" >/dev/null 2>&1 || log "WARN: efibootmgr -o failed (firmware may restrict changes)."
}

finalize_uefi_boot_entry_and_order_host() {
  step "Finalize UEFI boot entry: ensure GRUB ('Ubuntu') is primary bootloader"
  command -v efibootmgr >/dev/null 2>&1 || { log "WARN: efibootmgr not available on host; skipping BootOrder changes."; return 0; }
  [[ -d /sys/firmware/efi/efivars ]] || { log "WARN: efivars not mounted; skipping BootOrder changes."; return 0; }

  local esp_disk esp_pnum loader vendor
  esp_disk="$(esp_parent_disk "$ESP_PART")" || { log "WARN: Could not determine parent disk for ESP_PART=$ESP_PART"; return 0; }
  esp_pnum="$(esp_part_number "$ESP_PART")" || { log "WARN: Could not determine partition number for ESP_PART=$ESP_PART"; return 0; }
  loader="$(uefi_loader_path_on_esp)" || { log "WARN: Could not locate Ubuntu EFI loader on ESP; skipping NVRAM entry changes."; return 0; }

  log "ESP device: $ESP_PART (disk=$esp_disk part=$esp_pnum)"
  log "Ubuntu EFI loader path: $loader"

  # Create or reuse a NVRAM entry named exactly "Ubuntu"
  local ubu
  ubu="$(efibootmgr_get_bootnum_by_label "Ubuntu")"

  if [[ -z "$ubu" ]]; then
    log "Creating UEFI boot entry: Ubuntu"
    efibootmgr -c -d "$esp_disk" -p "$esp_pnum" -L "Ubuntu" -l "$loader" >/dev/null 2>&1 || \
      log "WARN: efibootmgr -c failed (firmware may block NVRAM writes)."
    ubu="$(efibootmgr_get_bootnum_by_label "Ubuntu")"
  else
    log "Found existing UEFI boot entry 'Ubuntu' (Boot$ubu)"
  fi

  if [[ -n "$ubu" ]]; then
    # Set timeout to something usable (does not affect all firmwares)
    efibootmgr -t 3 >/dev/null 2>&1 || true

    # Prefer Ubuntu first in BootOrder; keep the rest in current order.
    efibootmgr_set_bootorder_prefer "$ubu"

    vendor="$(detect_system_vendor)"
    if [[ "$vendor" == *"hp"* || "$vendor" == *"hewlett-packard"* ]]; then
      # HP firmwares sometimes cling to WindowsBootMgr; BootNext is a strong hint for the next reboot.
      log "HP firmware detected ('$vendor'): setting BootNext=Ubuntu for next boot (best-effort)"
      efibootmgr -n "$ubu" >/dev/null 2>&1 || log "WARN: efibootmgr -n failed."
    fi
  else
    log "WARN: Could not confirm an 'Ubuntu' NVRAM entry; firmware may still boot Windows first."
  fi

  # Record current EFI vars state for troubleshooting
  efibootmgr -v >"$TARGET_MNT/$BUILD_DIR_REL/efibootmgr-after.txt" 2>/dev/null || true
}
create_user_and_hostname_finalize() {
  step "Create user and set passwords"

  # Basic validation: POSIX-ish username (no spaces)
  if ! [[ "${USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "ERROR: Invalid username '${USERNAME}'. Use lowercase letters/numbers/underscore/dash, starting with a letter or underscore." >&2
    exit 1
  fi

  local groups_csv q_user q_real q_pass q_groups
  groups_csv="$(IFS=,; echo "${USER_GROUPS[*]}")"

  # Safely embed values into a small script executed inside the chroot.
  q_user="$(printf "%q" "${USERNAME}")"
  q_real="$(printf "%q" "${REALNAME}")"
  q_pass="$(printf "%q" "${USERPASS}")"
  q_groups="$(printf "%q" "${groups_csv}")"

  cat >"$TARGET_MNT/tmp/99-create-user.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

USERNAME=${q_user}
REALNAME=${q_real}
USERPASS=${q_pass}
GROUPS_CSV=${q_groups}

getent group 1000 >/dev/null 2>&1 || groupadd -g 1000 "\${USERNAME}" || true
id -u "\${USERNAME}" >/dev/null 2>&1 || useradd -m -u 1000 -g 1000 -c "\${REALNAME}" -s /bin/bash "\${USERNAME}"
usermod -aG "\${GROUPS_CSV}" "\${USERNAME}"
echo "\${USERNAME}:\${USERPASS}" | chpasswd
echo "root:\${USERPASS}" | chpasswd
EOF

  chmod 0755 "$TARGET_MNT/tmp/99-create-user.sh"
  chroot_cmd "/tmp/99-create-user.sh"
  rm -f "$TARGET_MNT/tmp/99-create-user.sh" || true
}

apt_cleanup_and_build_artifacts() {
  step "Write build artifacts and clean apt"
  mkdir -p "$TARGET_MNT/$BUILD_DIR_REL" "$TARGET_MNT/$REPO_DIR_REL"
  cp -f "$BUILD_LOG_TMP" "$TARGET_MNT/$BUILD_DIR_REL/install.log" || true
  chroot_cmd "apt autoremove -y --purge || true"
  chroot_cmd "apt clean || true"
}

### ------------------------------ MAIN ------------------------------------ ###
main() {
  require_root
  require_uefi

  step "Collect user inputs"
  read_nonempty HOSTNAME "Target hostname"
  read_nonempty USERNAME "New username"
  read_nonempty REALNAME "Full real name"
  read_password_confirm_loop USERPASS "User password"
  read_password_confirm_loop LUKSPASS "LUKS disk encryption passphrase"
  read_nonempty TZ "Timezone (IANA format, e.g. America/Los_Angeles)" "America/Los_Angeles"
  read_nonempty LOCALE "Locale" "en_US.UTF-8"

  disable_host_cdrom_sources_and_prefer_ports

  step "Install required tooling in ISO environment (best-effort)"
  apt_host_install_if_missing \
    debootstrap btrfs-progs cryptsetup parted dosfstools e2fsprogs util-linux     python3 python3-pip arch-install-scripts

  install_gdown_on_host

  choose_disk
  choose_free_region
  create_partitions_non_destructive
  format_and_label_partitions
  mount_for_subvol_create
  mount_target_layout
  find_and_mount_esp
  setup_swapfile_btrfs

  debootstrap_base
  write_apt_sources_target
  mount_kernel_interfaces

  install_arch_install_scripts_host
  generate_fstab_and_crypttab
  configure_target_basic_files

  install_packages_in_chroot
  configure_locale_timezone
  configure_network_manager_best_effort

  download_debs_with_gdown_into_target
  install_custom_kernel_and_tools_debs

  if [[ "$ENFORCE_CUSTOM_KERNEL" -eq 1 ]]; then enforce_custom_kernel_only; else log "Custom kernel enforcement disabled by flag."; fi

  install_platform_repo_packages

  # DTBs and DTB-driven GRUB entries:
  # - Copy ONLY the DTBs referenced by the currently-booted ISO GRUB menu
  # - Generate a DTB submenu from that manifest
  # - Bundle those DTBs into initramfs (best-effort parity with ISO)
  sync_dtbs_for_grub_menu
  install_iso_grub_dtb_and_windows_entries
  install_initramfs_iso_dtb_hook

  force_initramfs_modules
  update_initramfs_all_kernels
  verify_crypttab_and_initramfs_has_luks_support

  # Windows menu via os-prober (after linux tooling is installed)
  # enable_os_prober_in_target (removed)


  install_grub_uefi_in_chroot
  finalize_uefi_boot_entry_and_order_host
  create_user_and_hostname_finalize
  apt_cleanup_and_build_artifacts

  step "DONE"
  echo
  echo "✅ Install staged to $TARGET_MNT."
  echo "Next: reboot (verify /etc/fstab, /etc/crypttab, and /boot/efi contents first)."
  echo
}

main "$@"
