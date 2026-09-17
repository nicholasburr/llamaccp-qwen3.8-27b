# !/bin/bash

# --- Variables --- 
GRUB_PARAMS="iommu=pt amdgpu.gttsize=126976 ttm.pages_limit=32505856"
GRUB_FILE="/etc/default/grub"

# --- Asserts --- 
if [ "$EUID" -ne 0 ]; then 
  echo "This script requires root."
  exit 1
fi

# --- Grub ---
echo "Backing up $GRUB_FILE..."
cp $GRUB_FILE "${GRUB_FILE}.bak"

echo "Updating $GRUB_FILE..."
if grep -q "iommu=off" "$GRUB_FILE"; then
    echo "Parameters already seem to exist in $GRUB_FILE. Skipping edit."
else
    sed -i "/^GRUB_CMDLINE_LINUX=/ s/\"$/ $GRUB_PARAMS\"/" $GRUB_FILE
    echo "Parameters added successfully."
fi

echo "Regenerating GRUB configuration..."
grub2-mkconfig -o /boot/grub2/grub.cfg

# --- Tuned --- 
echo "Installing tuned..."
dnf install -y tuned

echo "Enabling and starting tuned..."
systemctl enable --now tuned

echo "Disabling tuned-ppd..."
systemctl disable --now tuned-ppd
systemctl mask tuned-ppd --no-warn

echo "Disabling tuned-ppd..."
systemctl disable --now upower
systemctl mask upower --no-warn

if tuned-adm list | grep -q "accelerator-performance"; then
    echo "Applying 'accelerator-performance' profile..."
    tuned-adm profile accelerator-performance
else
    echo "Warning: 'accelerator-performance' profile not found."
fi

echo -n "Active Tuned Profile: "
tuned-adm active

# --- podman-compose IPC patch ---
# `podman compose` on this system delegates to the Python `podman-compose`
# package (v1.6.0; the podman build here has no built-in compose). That
# version handles the `shm_size` compose key but has NO `ipc` handling, so
# `ipc: host` in compose.yaml is silently ignored and the ROCm
# qwen3.8-27b container runs in a private ~64MB /dev/shm namespace. Loading
# the 27B model at 256K+ context exhausts it and the container dies during
# model load with:
#   "Memory critical error ... Reason: Memory in use"  (SIGSEGV / exit 139)
# A plain `podman run --ipc=host` works; the compose path needs the patch below.
# This section patches podman-compose so the compose file honors `ipc` too.
#
# CAVEAT: this edits a system file. If the podman-compose package is later
# reinstalled/updated the patch is lost (re-run this script to re-apply).

echo "Patching podman-compose to honor the 'ipc' compose key..."

# Locate the podman_compose module (path depends on the installed python).
PC_PY="$(python3 -c 'import os, podman_compose; print(os.path.realpath(podman_compose.__file__))' 2>/dev/null)"
if [ -z "$PC_PY" ] || [ ! -f "$PC_PY" ]; then
    PC_PY="$(find /usr/lib /usr/local/lib -name podman_compose.py 2>/dev/null | head -n1)"
fi

if [ -z "$PC_PY" ] || [ ! -f "$PC_PY" ]; then
    echo "  SKIP: could not locate podman_compose.py (is podman-compose installed?)."
elif grep -q -- '--ipc' "$PC_PY"; then
    echo "  Already patched: $PC_PY"
elif grep -q -- '--shm-size' "$PC_PY"; then
    echo "  Patching: $PC_PY"
    cp "$PC_PY" "${PC_PY}.bak-ipc"
    sed -i '/--shm-size/a\    if cnt.get("ipc"):\n        podman_args.extend(["--ipc", str(cnt["ipc"])])' "$PC_PY"
    if grep -q -- '--ipc' "$PC_PY" && python3 -c "import ast; ast.parse(open('$PC_PY').read())" 2>/dev/null; then
        echo "  Patched OK. Backup saved at: ${PC_PY}.bak-ipc"
    else
        echo "  ERROR: patch failed; restoring original from backup."
        cp "${PC_PY}.bak-ipc" "$PC_PY"
    fi
else
    echo "  SKIP: no '--shm-size' anchor found in $PC_PY (version mismatch?). Patch manually."
fi

echo "------------------------------------------------------"
echo "Reboot to update GRUB."
echo "------------------------------------------------------"
