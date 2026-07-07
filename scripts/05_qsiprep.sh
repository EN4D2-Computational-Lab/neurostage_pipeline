#!/usr/bin/env bash
# Step 05 — QSIPrep (DWI preprocessing)
# Auto-detects GPU and uses eddy_cuda if available (controlled by EDDY_GPU in .env)
set -euo pipefail

EDDY_GPU="${EDDY_GPU:-AUTO}"
EDDY_CONFIG_DIR="$PIPELINE_BASE/configs"
EDDY_CONFIG_CPU="$EDDY_CONFIG_DIR/eddy_cpu.json"
EDDY_CONFIG_GPU="$EDDY_CONFIG_DIR/eddy_gpu.json"
mkdir -p "$EDDY_CONFIG_DIR"

# ── Write eddy config files if missing ───────────────────────────────────────
if [[ ! -f "$EDDY_CONFIG_CPU" ]]; then
    cat > "$EDDY_CONFIG_CPU" << 'JSON'
{
  "flm": "quadratic",
  "slm": "linear",
  "niter": 5,
  "repol": true,
  "cnr_maps": true,
  "use_cuda": false
}
JSON
fi

if [[ ! -f "$EDDY_CONFIG_GPU" ]]; then
   cat > "$EDDY_CONFIG_GPU" << 'JSON'
{
  "flm": "quadratic",
  "slm": "linear",
  "niter": 5,
  "repol": true,
  "cnr_maps": true,
  "use_cuda": true
}
JSON
fi

# ── GPU detection ─────────────────────────────────────────────────────────────
USE_GPU=0
if [[ "$EDDY_GPU" == "ON" ]]; then
    USE_GPU=1
elif [[ "$EDDY_GPU" == "AUTO" ]]; then
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        echo "  GPU detected: $GPU_NAME — using eddy_cuda"
        USE_GPU=1
    else
        echo "  No GPU detected — using CPU eddy"
    fi
elif [[ "$EDDY_GPU" == "OFF" ]]; then
    echo "  EDDY_GPU=OFF — using CPU eddy"
fi

# ════════════════════════════════════════════════════════════════
# DWI Pre-flight Sanity Check
# ════════════════════════════════════════════════════════════════
SUB_DIR="$BIDS_DIR/sub-$SUBJECT_ID"
DWI_DIR="$SUB_DIR/dwi"
FMAP_DIR="$SUB_DIR/fmap"
TEMP_DELETED="$SUB_DIR/temp_deleted"

# Track what we do so we can undo it perfectly
RESTORED_FROM_DELETED=()  # files moved to temp_deleted → restore to dwi
RESTORED_FROM_FMAP=()     # files moved to fmap → restore to dwi

mkdir -p "$FMAP_DIR" "$TEMP_DELETED"
echo ""
echo " [DWI-CHECK] Scanning: $DWI_DIR"

# ── Helper: get FSL dim4 ──────────────────────────────────────────────────────
get_dim4() {
    fslval "$1" dim4 2>/dev/null || echo "0"
}

# ── Helper: extract PhaseEncodingDirection from JSON ─────────────────────────
get_pe_dir() {
    local json_file="$1"
    if [[ -f "$json_file" ]] && command -v grep &>/dev/null; then
        # Simple extraction extracting the value between quotes
        grep -o '"PhaseEncodingDirection"[[:space:]]*:[[:space:]]*"[^"]*"' "$json_file" | sed 's/.*"\(.*\)".*/\1/' || echo ""
    else
        echo ""
    fi
}

# ── STEP 1: Check bval/bvec completeness ─────────────────────────────────────
echo " [DWI-CHECK] Step 1 — Checking bval/bvec completeness..."
for nii in "$DWI_DIR"/*.nii.gz; do
    [[ -f "$nii" ]] || continue
    base="${nii%.nii.gz}"
    stem=$(basename "$base")
    
    missing=""
    [[ ! -f "${base}.bval" ]] && missing="$missing bval"
    [[ ! -f "${base}.bvec" ]] && missing="$missing bvec"
    [[ ! -f "${base}.json" ]] && missing="$missing json"
    
    if [[ -n "$missing" ]]; then
        echo " [DWI-CHECK] WARN: $stem missing:$missing — moving to temp_deleted/"
        mv "$nii" "$TEMP_DELETED/"
        RESTORED_FROM_DELETED+=("$stem.nii.gz")
        for ext in bval bvec json; do
            [[ -f "${base}.${ext}" ]] && mv "${base}.${ext}" "$TEMP_DELETED/" && \
                RESTORED_FROM_DELETED+=("$stem.${ext}")
        done
    fi
done

# ── STEP 2: Detect and relocate opposite PE b0-only runs to fmap/ ───────────
echo " [DWI-CHECK] Step 2 — Detecting standalone b0 volumes with opposite PE..."
mkdir -p "$FMAP_DIR"
B0_COUNT=0

# First, find the baseline PhaseEncodingDirection of the main multi-shell DWI data
MAIN_PE_DIR=""
for nii in "$DWI_DIR"/*.nii.gz; do
    [[ -f "$nii" ]] || continue
    base="${nii%.nii.gz}"
    bval_file="${base}.bval"
    json_file="${base}.json"
    
    unique_bvals=$(awk '{for(i=1;i<=NF;i++) printf "%d\n", int(($i+25)/50)*50}' "$bval_file" | sort -nu)
    n_nonzero=$(echo "$unique_bvals" | awk '$1 > 50' | wc -l)
    
    # If it contains diffusion shells, this is our baseline file
    if [[ "$n_nonzero" -gt 0 ]]; then
        MAIN_PE_DIR=$(get_pe_dir "$json_file")
        if [[ -n "$MAIN_PE_DIR" ]]; then
            echo " [DWI-CHECK] Found primary DWI series phase encoding direction: '$MAIN_PE_DIR'"
            break
        fi
    fi
done

# Now scan again to target b0 runs and check their compatibility
for nii in "$DWI_DIR"/*.nii.gz; do
    [[ -f "$nii" ]] || continue
    base="${nii%.nii.gz}"
    stem=$(basename "$base")
    bval_file="${base}.bval"
    json_file="${base}.json"
    
    unique_bvals=$(awk '{for(i=1;i<=NF;i++) printf "%d\n", int(($i+25)/50)*50}' "$bval_file" | sort -nu)
    n_nonzero=$(echo "$unique_bvals" | awk '$1 > 50' | wc -l)
    
    if [[ "$n_nonzero" -eq 0 ]]; then
        # Condition A met: This is a b0-only volume
        CURRENT_PE_DIR=$(get_pe_dir "$json_file")
        
        IS_OPPOSITE=0
        normalize_pe() {
            echo "$1" | sed 's/-$//'
        }

        if [[ -n "$MAIN_PE_DIR" && -n "$CURRENT_PE_DIR" ]]; then
            MAIN_NORM=$(normalize_pe "$MAIN_PE_DIR")
            CURR_NORM=$(normalize_pe "$CURRENT_PE_DIR")

            if [[ "$MAIN_PE_DIR" != "$CURRENT_PE_DIR" && "$MAIN_NORM" == "$CURR_NORM" ]]; then
                IS_OPPOSITE=1
            fi
        fi
        
        # Condition B met: It is verified as the opposite phase encoding direction
        if [[ "$IS_OPPOSITE" -eq 1 ]]; then
            echo " [DWI-CHECK] Verified b0-only run with opposite PE ($CURRENT_PE_DIR vs $MAIN_PE_DIR): $stem — moving to fmap/"
            B0_COUNT=$((B0_COUNT + 1))
            for ext in nii.gz bval bvec json; do
                src="${base}.${ext}"
                if [[ "$ext" == "nii.gz" ]]; then src="$nii"; fi
                
                if [[ -f "$src" ]]; then
                    mv "$src" "$FMAP_DIR/"
                    RESTORED_FROM_FMAP+=("$stem.${ext}")
                fi
            done
        else
            echo " [DWI-CHECK] Skip: $stem is b0-only but PE direction ('$CURRENT_PE_DIR') is NOT opposite to main ('$MAIN_PE_DIR'). Leaving in place or quarantine."
            # Optional: Quarantine it to temp_deleted if you do not want it evaluated as normal DWI
            echo " [DWI-CHECK] Quarantining non-opposite b0-only run to prevent concatenation error."
            mv "$nii" "$TEMP_DELETED/"
            RESTORED_FROM_DELETED+=("$stem.nii.gz")
            for ext in bval bvec json; do
                [[ -f "${base}.${ext}" ]] && mv "${base}.${ext}" "$TEMP_DELETED/" && \
                    RESTORED_FROM_DELETED+=("$stem.${ext}")
            done
        fi
    fi
done

if [[ "$B0_COUNT" -eq 0 ]]; then
    echo " [DWI-CHECK] No valid opposite-PE standalone b0 runs found."
fi

# ── STEP 3: Verify remaining DWI files are 4D ────────────────────────────────
echo " [DWI-CHECK] Step 3 — Verifying remaining DWI files are 4D..."
DWI_OK=0
DWI_BAD=0

for nii in "$DWI_DIR"/*.nii.gz; do
    [[ -f "$nii" ]] || continue
    stem=$(basename "${nii%.nii.gz}")
    dim4=$(get_dim4 "$nii")
    
    if [[ "$dim4" -ge 2 ]]; then
        echo " [DWI-CHECK] OK — $stem (dim4=$dim4)"
        DWI_OK=$((DWI_OK + 1))
    elif [[ "$dim4" -eq 1 ]]; then
        echo " [DWI-CHECK] WARN: $stem is 3D (dim4=1) — moving to temp_deleted/"
        base="$DWI_DIR/$stem"
        mv "$nii" "$TEMP_DELETED/"
        RESTORED_FROM_DELETED+=("$stem.nii.gz")
        for ext in bval bvec json; do
            [[ -f "${base}.${ext}" ]] && mv "${base}.${ext}" "$TEMP_DELETED/" && \
                RESTORED_FROM_DELETED+=("$stem.${ext}")
        done
        DWI_BAD=$((DWI_BAD + 1))
    else
        echo " [DWI-CHECK] ERROR: Could not read dim4 for $stem — skipping"
    fi
done

echo " [DWI-CHECK] Summary: $DWI_OK valid DWI run(s), $DWI_BAD quarantined, $B0_COUNT moved to fmap/"

if [[ "$DWI_OK" -eq 0 ]]; then
    echo " [DWI-CHECK] ERROR: No valid 4D DWI files remain after checks. Aborting."
    # Restore everything before exit
    for f in "${RESTORED_FROM_DELETED[@]}"; do [[ -f "$TEMP_DELETED/$f" ]] && mv "$TEMP_DELETED/$f" "$DWI_DIR/"; done
    for f in "${RESTORED_FROM_FMAP[@]}"; do [[ -f "$FMAP_DIR/$f" ]] && mv "$FMAP_DIR/$f" "$DWI_DIR/"; done
    rmdir --ignore-fail-on-non-empty "$TEMP_DELETED" "$FMAP_DIR" 2>/dev/null || true
    exit 1
fi
echo ""

# ── Remove empty fmap dir if nothing was moved there ───────────────────────
# ── Conditionally add --ignore fieldmaps if no fmap data present ────────────
SDC_ARG=""
if [[ -d "$FMAP_DIR" ]] && [[ -z "$(ls -A "$FMAP_DIR" 2>/dev/null)" ]]; then
    rmdir "$FMAP_DIR"
    SDC_ARG="--ignore fieldmaps"
    echo " [DWI-CHECK] No fieldmaps present — removed empty fmap/ directory and also adding --ignore fieldmaps to QSIPrep command."
fi

# ── Remove empty fmap dir if nothing was moved there ───────────────────────
if [[ -d "$TEMP_DELETED" ]] && [[ -z "$(ls -A "$TEMP_DELETED" 2>/dev/null)" ]]; then
    rmdir "$TEMP_DELETED"
    echo " [DWI-CHECK] No quarantined files present — removed empty temp_deleted/ directory."
fi

# ════════════════════════════════════
# Execute QSIPrep
# ════════════════════════════════════

# Trap to restore files even if QSIPrep crashes
restore_dwi_files() {
    echo ""
    echo " [DWI-RESTORE] Restoring original DWI directory structure..."

    # Restore temp_deleted
    if [[ -d "$TEMP_DELETED" ]]; then
        find "$TEMP_DELETED" -type f -exec mv {} "$DWI_DIR/" \; 2>/dev/null || true
        echo " [DWI-RESTORE] Restored everything from temp_deleted"
    fi

    # Restore fmap
    if [[ -d "$FMAP_DIR" ]]; then
        find "$FMAP_DIR" -type f -exec mv {} "$DWI_DIR/" \; 2>/dev/null || true
        echo " [DWI-RESTORE] Restored everything from fmap"
    fi

    rmdir --ignore-fail-on-non-empty "$TEMP_DELETED" "$FMAP_DIR" 2>/dev/null || true
    echo " [DWI-RESTORE] Done."
}
trap restore_dwi_files EXIT
trap restore_dwi_files INT
trap restore_dwi_files TERM

# ── Build docker run args ─────────────────────────────────────────────────────
# Define the images
IMAGE_STOCK="pennlinc/qsiprep:latest"
IMAGE_FIXED="pennlinc/qsiprep:fixed"

DOCKER_EXTRA=""
EDDY_CONFIG_ARG=""
SELECTED_IMAGE="" # We will set this below

if [[ "$USE_GPU" == "1" ]]; then
    DOCKER_EXTRA="--gpus all"
    EDDY_CONFIG_ARG="--eddy-config /configs/eddy_gpu.json"
    SELECTED_IMAGE="$IMAGE_FIXED" # Use the fixed image for GPU
    echo "  Eddy config: GPU (slice-to-vol correction enabled)"
else
    EDDY_CONFIG_ARG="--eddy-config /configs/eddy_cpu.json"
    SELECTED_IMAGE="$IMAGE_STOCK" # Use the stock image for CPU
    echo "  Eddy config: CPU"
fi

docker run --rm \
  $DOCKER_EXTRA \
  -v "$BIDS_DIR/$SUB_LABEL:/data:ro" \
  -v "$QSIPREP_OUT:/out" \
  -v "$FS_LICENSE:/license:ro" \
  -v "$EDDY_CONFIG_DIR:/configs:ro" \
  -v "$WORKING_DIR:/work" \
  "$SELECTED_IMAGE" \
  /data /out participant \
  --skip-bids-validation \
  --participant-label "$SUBJECT_ID" \
  --fs-license-file /license \
  --output-resolution "$OUTPUT_RESOLUTION" \
  --nprocs "$N_THREADS" \
  --mem "$MEM_GB" \
  --hmc-model eddy \
  --work-dir /work \
  $EDDY_CONFIG_ARG \
  $SDC_ARG

echo "  [QSIPrep] Output: $QSIPREP_OUT"

echo " [QSIPrep] Restore will happen on EXIT trap."
# trap fires here automatically on EXIT → restores files