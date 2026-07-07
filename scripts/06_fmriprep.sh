#!/usr/bin/env bash
# Step 06 — fMRIPrep (resting-state / task fMRI)
set -euo pipefail

# ── Check for BOLD data ───────────────────────────────────────────────────────
# fMRIPrep processes ALL *_bold.nii.gz files found under func/ in one run.
# We only need one to exist to confirm there is work to do.
mapfile -t BOLD_FILES < <(find "$SUB_BIDS_DIR/func" -name "*_bold.nii.gz" 2>/dev/null | sort)

FUNC_DIR="$SUB_BIDS_DIR/func"
TMP_DEL_DIR="$SUB_BIDS_DIR/tmp_func_del"

mkdir -p "$TMP_DEL_DIR"

# ── Restore trap — registered BEFORE validation moves anything, so any crash
# from this point forward (including inside the validation loop itself) is
# covered. Previously the restore only happened via a manual block at the
# bottom of the script, which under `set -euo pipefail` never ran if `docker
# run` failed — quarantined files were left in tmp_func_del/ indefinitely and
# silently vanished from the BIDS dataset for any later step or re-run.
_restore_quarantined() {
    if [[ -d "$TMP_DEL_DIR" ]] && [[ -n "$(ls -A "$TMP_DEL_DIR" 2>/dev/null)" ]]; then
        echo "  Restoring quarantined BOLD files..."
        mv "$TMP_DEL_DIR"/* "$FUNC_DIR/" 2>/dev/null || true
    fi
    rmdir "$TMP_DEL_DIR" 2>/dev/null || true
}
trap _restore_quarantined EXIT

# ── BOLD Pre-flight validation ───────────────────────────────────────────────
VALID_BOLD_FILES=()
BAD_BOLD_FILES=()

get_dim4() {
    fslval "$1" dim4 2>/dev/null || echo "0"
}

echo "  Running BOLD validation..."

# Below this, fMRIPrep's own nodes (SDC, confound regression, ICA-AROMA if
# enabled) are unreliable. Matches the MIN_TIMEPOINTS threshold used in
# bids_filter_gen.py for MRIQC, so MRIQC and fMRIPrep agree on which runs
# for a given subject are usable rather than disagreeing on the same data.
MIN_BOLD_TIMEPOINTS=10

for f in "${BOLD_FILES[@]}"; do
    stem=$(basename "$f" .nii.gz)
    dim4=$(get_dim4 "$f")

    if [[ "$dim4" -ge "$MIN_BOLD_TIMEPOINTS" ]]; then
        VALID_BOLD_FILES+=("$f")
        echo "    OK  : $stem (dim4=$dim4)"
    else
        BAD_BOLD_FILES+=("$f")
        echo "    BAD : $stem (dim4=$dim4, need >=$MIN_BOLD_TIMEPOINTS) → quarantining"
        mv "$f" "$TMP_DEL_DIR/"
        for ext in json tsv; do
            sidecar="${f%.nii.gz}.${ext}"
            [[ -f "$sidecar" ]] && mv "$sidecar" "$TMP_DEL_DIR/"
        done
    fi
done

# ── Safety check ─────────────────────────────────────────────────────────────
if [[ ${#BOLD_FILES[@]} -eq 0 ]]; then
    echo "  No BOLD data found for $SUB_LABEL — skipping fMRIPrep."
    exit 0
fi

if [[ ${#VALID_BOLD_FILES[@]} -eq 0 ]]; then
    echo "  ERROR: No valid 4D BOLD runs found — aborting fMRIPrep."
    exit 1
fi

echo "  Found ${#VALID_BOLD_FILES[@]} BOLD run(s) — fMRIPrep will process all:"
for f in "${VALID_BOLD_FILES[@]}"; do echo "    $(basename "$f")"; done

# ── FreeSurfer reuse ──────────────────────────────────────────────────────────
FS_DONE="$FS_OUTPUT_DIR/$SUB_LABEL/mri/aseg.mgz"
FS_ARG=""
FS_VOL=""
if [[ -f "$FS_DONE" ]]; then
    echo "  Using existing FreeSurfer output."
    FS_VOL="-v $FS_OUTPUT_DIR:/fs_output"
    FS_ARG="--fs-subjects-dir /fs_output"
else
    echo "  FreeSurfer output not found — fMRIPrep will run its own recon (slower)."
fi

# ── Run fMRIPrep (processes all BOLD runs in one call) ───────────────────────
docker run --rm \
    -v "$SUB_BIDS_DIR:/data:ro" \
    -v "$FMRIPREP_OUT:/out" \
    -v "$FS_LICENSE:/license:ro" \
    -v "$WORKING_DIR:/work" \
    $FS_VOL \
    "$FMRIPREP_IMAGE" \
    /data /out participant \
    --participant-label "$SUBJECT_ID" \
    --fs-license-file /license \
    --nprocs "$N_THREADS" \
    --mem "$MEM_GB" \
    --output-spaces MNI152NLin2009cAsym:res-1 \
    --work-dir /work \
    --skip-bids-validation \
    $FS_ARG

echo "  fMRIPrep output: $FMRIPREP_OUT"
echo "  Restore of quarantined BOLD files will happen automatically on exit."