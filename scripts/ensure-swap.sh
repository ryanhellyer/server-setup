#!/usr/bin/env bash
# =============================================================================
# ensure-swap.sh — create + enable a swapfile if none exists. Important on
# small-RAM boxes (2 GB) to avoid OOM / swap-thrash. Idempotent.
#   SWAP_SIZE=2G   (default; override in .env)
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

if swapon --show 2>/dev/null | grep -q .; then
  echo "Swap already enabled."
  exit 0
fi

SIZE="${SWAP_SIZE:-2G}"
case "$SIZE" in
  *G) MB=$(( ${SIZE%G} * 1024 )) ;;
  *M) MB=${SIZE%M} ;;
  *)  MB=2048 ;;
esac

if [ ! -e /swapfile ]; then
  echo "==> creating ${SIZE} swapfile"
  fallocate -l "$SIZE" /swapfile 2>/dev/null \
    || dd if=/dev/zero of=/swapfile bs=1M count="$MB" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
fi

# Activate. A leftover file that was never mkswap'd (interrupted first run)
# fails swapon — repair it once instead of silently writing a broken fstab
# entry that would error on every boot.
if ! swapon /swapfile 2>/dev/null; then
  echo "  (swapon failed — re-running mkswap and retrying)"
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null 2>&1 || true
  swapon /swapfile 2>/dev/null
fi

if swapon --show 2>/dev/null | grep -q .; then
  grep -qs '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "Swapfile ${SIZE} enabled."
else
  # No fstab entry: a broken one would error on every boot.
  echo "!! /swapfile exists but could not be enabled as swap — no fstab entry written." >&2
  echo "!! Inspect it (file /swapfile), fix or delete it, then re-run." >&2
fi
