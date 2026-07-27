#!/usr/bin/env bash
# ============================================================
# POCO X3 Pro Debloat - One-liner installer
# ============================================================
# Downloads debloat.sh + restore.sh from GitHub and runs debloat.sh.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/9M2PJU/9M2PJU-POCO-X3-Pro-Debloat-Script/main/install.sh | bash
#
# Variants:
#   ... | bash -s -- --list       # preview only, change nothing
#   ... | bash -s -- --no-run     # download only, don't run
#   ... | bash -s -- --yes        # non-interactive, remove all batches
#   ... | bash -s -- --batch 1    # run only batch N (1-5)
#   ... | bash -s -- --dir ~/px3  # install to a specific directory
# ============================================================

set -u

REPO="9M2PJU/9M2PJU-POCO-X3-Pro-Debloat-Script"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
INSTALL_DIR="$(pwd)/poco-x3-pro-debloat"
RUN=1
DEBLOAT_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-run) RUN=0 ;;
    --dir) INSTALL_DIR="$2"; shift ;;
    --list|--yes|--batch) DEBLOAT_ARGS+=("$1") ;;
    --batch=*) DEBLOAT_ARGS+=("$1") ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) DEBLOAT_ARGS+=("$1") ;;
  esac
  shift
done

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || { echo "ERROR: cannot cd to $INSTALL_DIR" >&2; exit 1; }

echo "Downloading scripts to: $INSTALL_DIR"
for f in debloat.sh restore.sh; do
  if ! curl -fsSL "${BASE_URL}/${f}" -o "$f"; then
    echo "ERROR: failed to download $f" >&2
    exit 1
  fi
  chmod +x "$f"
  echo "  got: $f"
done

if [ "$RUN" = "1" ]; then
  echo ""
  echo "Running debloat.sh..."
  bash debloat.sh "${DEBLOAT_ARGS[@]}"
else
  echo ""
  echo "Downloaded. Run manually when ready:"
  echo "  cd $INSTALL_DIR"
  echo "  bash debloat.sh"
fi
