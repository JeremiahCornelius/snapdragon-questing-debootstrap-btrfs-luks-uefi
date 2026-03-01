### (Ubuntu 25.10) Debootstrap + Chroot Installer (Qualcom Snapdragon ARM64, UEFI, LUKS1, BTRFS)
---

#  snapdragon-questing-debootstrap-btrfs-luks-uefi

A shell script that safely installs Ubuntu 25.10 from bootable ISO images made by Jens Glathe, to a suppoted target laptop, leveraging debootstrap, etc. 

Windows duel-boot configurations are expresly preserved. Creation of free space for new partitions is an exercise for the user!


Original ISO images are disributed from this Google Drive share:

https://drive.google.com/drive/folders/1sc_CpqOMTJNljfvRyLG-xdwB0yduje_O

Installation requires full-network access, as sources from the local ISO image repository and casper filesystem are ignored in favor of latest available packages.

Installation SHOULD be possible for these machines from Jen's kernel and device-trees, and possibly others with some effort by the installer.

- **Microsoft Windows Dev Kit 2023** 
- **Lenovo Thinkpad X13s** 
- **HP Omnibook X AI 14-fe0**
- **Lenovo Thinkpad T14s**
- **Qualcomm Snapdragon Dev Kit for Windows** 
- Acer Swift sf14-11
- Lenovo Yoga Slim 7x
- Asus Vivobook S15
- Acer Swift Go sfg14-01
- Asus Vivobook S15
- HP Omnibook X AI 14-fe1
- **Lenovo Ideapad 5 2-in-1 14Q8X9 (83GH)**
- Lenovo Ideapad Slim 5x 14Q8X9 (83HL)
- **Lenovo Thinkbook 16 G7 QOY (21NH)** 
- Microsoft SP12

Though in some ways "hacky", this script performs a **manual, deterministic-style installation of Ubuntu 25.10 (“Questing”) for ARM64** using **debootstrap + chroot**, executed from a **booted Ubuntu ISO** environment. It is designed for **UEFI systems with Secure Boot disabled**, and focuses on reproducibility, auditability, and safe multi-boot coexistence by **avoiding destructive disk wipes** and **creating new partitions only inside user-confirmed free space**.

User prompted input is supplied upfront for machine and user identification, timezone, locale and LUKS passphrase, with regard to the safe collection and handling of secrets as confirmed, ephemeral runtime variables.

The resulting system is a **LUKS1-encrypted root** hosting a structured **BTRFS subvolume layout**, with a dedicated **ext4 /boot** partition and an existing **ESP mounted at /boot/efi** using explicit VFAT mount options. It installs a GNOME desktop stack (Ubuntu + VanillaOS GNOME components), configures **NetworkManager** for desktop-friendly networking, and enforces a **custom kernel/tooling set retrieved from Google Drive** using `gdown`, including optional kernel apt-pinning behavior to prevent vendor kernels from being installed later.

## Resulting Target Configuration

- **Platform**: Ubuntu 25.10 (“Questing”), **arm64**, from `ports.ubuntu.com`
- **Boot Mode**: **UEFI-only** (script aborts if not UEFI); assumes **Secure Boot disabled**
- **Disk Layout** (non-destructive multi-boot friendly):
  - New **500 MiB ext4** partition labeled `BOOT` mounted at `/boot`
  - New encrypted root partition:
    - **LUKS1 container**
    - BTRFS filesystem inside LUKS, labeled `UBUNTU`
    - Structured BTRFS subvolumes mounted with `compress=zstd` and `space_cache=v2`
- **ESP**: Existing VFAT partition mounted at `/boot/efi` with explicit mount options:
  - `rw,noatime,fmask=0022,dmask=0022,codepage=437,iocharset=utf8,shortname=mixed,errors=remount-ro`
- **Swap**: BTRFS subvolume `@swap` containing a **NODATACOW swapfile**
- **Networking**: **NetworkManager** enabled (Netplan renderer set to NetworkManager if netplan exists; does not hard-fail)
- **Desktop Stack**: `ubuntu-desktop`, `ubuntu-session`, `vanilla-gnome-desktop`, `vanilla-gnome-default-settings`
- **Custom Kernel**:
  - Downloaded via `gdown` into `/opt/var/repository`
  - Installed via `apt install /path/to/*.deb` so dependencies are resolved
  - `update-initramfs -u -k all` executed after install
  - Initramfs cryptroot/cryptsetup presence is verified before GRUB configuration
- **User Provisioning**:
  - Prompts for username, real name, password (confirmed), hostname, timezone, locale
  - Attempts to create the user with UID/GID **1000**, and adds required supplementary groups

## Deterministic Guardrails and Governance Controls

This script emphasizes “deterministic-by-design” behavior with guardrails to prevent ambiguous or unsafe actions:

- **UEFI-only hard gate**: aborts if `/sys/firmware/efi` is not present.
- **Non-destructive partitioning policy**:
  - Scans disk free space
  - Presents free regions as explicit selectable choices
  - Requires a clear Y/N confirmation prior to partition creation
  - Creates partitions only inside the selected free region
- **Deterministic partition identification**:
  - Captures partitions before and after creation
  - Computes the exact set difference
  - Refuses to proceed unless **exactly two** new partitions are detected
- **Password confirmation loops**:
  - User password and LUKS passphrase must match by double entry
  - Mismatches trigger re-prompt (no early abort)
- **Build artifacts and logging**:
  - Writes operational artifacts into the target at `/opt/var/build`
  - Saves a complete install log, installed package list, and key identifiers (excluding the user password)
- **Failure transparency**:
  - On any failure, prints a bullet list of completed steps up to the failure point
  - Performs best-effort cleanup: unmounts target filesystems and closes LUKS mapping

## Principal Features

- **UEFI-only** installation flow with clear gating and user-friendly failure messaging
- **Multi-boot safe partitioning**:
  - No wiping of disks or partitions
  - New partitions created only in user-approved free space
- **LUKS1 root encryption** (explicitly LUKS1, not LUKS2), with `/etc/crypttab` generated deterministically
- **BTRFS subvolume hierarchy** created in a strict, deterministic order:
  - `@`, `@snapshots`, `@home`, `@root`, `@var@log`, `@var@lib@AccountsService`, `@var@lib@gdm3`, `@tmp`, `@swap`, `@home/.snapshots`, `@var@lib@docker`
- **Swapfile on BTRFS** in a dedicated `@swap` subvolume with NODATACOW semantics
- **Explicit /boot/efi mount options** for VFAT resilience and consistent permissions behavior
- **Chroot-based system installation** with `debootstrap` and target-bound mounts (`/dev`, `/proc`, `/sys`, `/dev/pts`)
- **NetworkManager-first networking**, optimized for GNOME desktop usability and plug-and-play devices
- **Custom kernel toolchain install** using `gdown` + local `.deb` repository staging:
  - Installs kernel packages via `apt` so dependencies are resolved
  - Forces initramfs module inclusion (crypto + btrfs) before rebuild
  - Verifies cryptroot + cryptsetup is present in initramfs before GRUB is configured
- **Kernel enforcement mode (default ON)**:
  - Purges common vendor kernel meta packages
  - Pins and `apt-mark hold`s the custom kernel packages
  - Prevents vendor kernels from being installed unintentionally later
- **GRUB2 UEFI install and configuration** from within the target chroot
- **Deterministic output artifacts** saved under `/opt/var/build` for auditability and repeatable operations

## Credits / Reference Inspiration

Theese efforts are heavily dependent on the work done by Jens Glathe, and a number of other contrubutors for the Ububtu Concept project, bringing distribution support to commodity ARM laptops built on the Qualcom Snapdragon SOC.

- **jglathe** *github repository*

https://github.com/jglathe/linux_ms_dev_kit

- **Tobias Heider *tobhe*** *and the contibutors on the Ubuntu Concept Project Discussion:*

https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800

---

This script’s debootstrap-and-chroot methodology is inspired by the manual installation approach documented by:

- **Silvenga**, *“Bypassing the installer: Manually installing Ubuntu”*  
https://silvenga.com/posts/bypassing-the-installer-manually-installing-ubuntu/

This script substantially builds upon that document's foundation for bypassing Calamares/Ubiquity installers for customized debootsrap installations with **LUKS1 + BTRFS subvolume topologies**.

---
## License

This is really modular, function-driven and well-defined shell logic that leverages best-practices and previously published guidance for policy-based use of `apt` tooling and Debian-style software packaging. It's an unfortunate fact that some form of license is required for the free sharing of such a script. GPL versions seem to be overkill, so we've defaulted to the MIT license. Be generous and respectful. I hope you find this useful.
