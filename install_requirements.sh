#!/usr/bin/env bash
# =============================================================================
# install_requirements.sh  — Run once on a new machine
# Installs Python deps and pulls Docker images listed in .env
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

echo "══════════════════════════════════════════════════════"
echo "  NeuroStage Pipeline — Dependency Installer"
echo "══════════════════════════════════════════════════════"

# ── Python packages ──────────────────────────────────────────────────────────
echo "[1/3] Installing Python packages..."
pip install --quiet dcm2bids dcm2niix pydicom tqdm colorama

# ── Docker images ────────────────────────────────────────────────────────────
echo "[2/3] Pulling Docker images (this may take a while)..."
for IMG in "$MRIQC_IMAGE" "$QSIPREP_IMAGE" "$FMRIPREP_IMAGE" "$ASLPREP_IMAGE"; do
    echo "  Pulling $IMG ..."
    docker pull "$IMG"
done

# ── Disk space warning ───────────────────────────────────────────────────────
echo "[3/3] Checking available disk space..."
AVAIL_GB=$(df -BG "$PIPELINE_BASE" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' || echo "?")
echo "  Available at $PIPELINE_BASE: ${AVAIL_GB}GB"
if [[ "$AVAIL_GB" != "?" && "$AVAIL_GB" -lt 200 ]]; then
    echo "  ⚠ WARNING: Recommended ≥200GB free per subject for full pipeline."
fi

echo ""
echo "✓ Done. Copy .env.template → .env, fill in your paths, then run:"
echo "    ./run_pipeline.sh"
