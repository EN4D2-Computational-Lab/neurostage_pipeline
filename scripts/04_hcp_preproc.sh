#!/usr/bin/env bash
# Step 04 — HCP Structural Pipeline
# Assumes HCPpipelines/ folder is inside $PIPELINE_BASE

# Quoted, and still sourced before strict mode for the same reason FreeSurfer's
# env is sourced before set -euo pipefail in run_pipeline.sh: fsl.sh itself may
# trip set -u/-e internals we don't control. `|| true` keeps a sourcing hiccup
# from killing the whole step silently before we even reach our own checks.
source "$FSLDIR/etc/fslconf/fsl.sh" || true
set -euo pipefail

SETUP_SCRIPT="$HCPPIPEDIR/Examples/Scripts/SetUpHCPPipeline.sh"

# ── Validate HCP folder exists ────────────────────────────────────────────────
[[ -d "$HCPPIPEDIR" ]] || { echo "ERROR: HCPpipelines not found at $HCPPIPEDIR"; exit 1; }
[[ -f "$SETUP_SCRIPT" ]] || { echo "ERROR: SetUpHCPPipeline.sh not found at $SETUP_SCRIPT"; exit 1; }

# ── Validate paths inside SetUpHCPPipeline.sh ─────────────────────────────────
echo "  Checking paths in SetUpHCPPipeline.sh ..."
SETUP_ERRORS=0

while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+([A-Z_]+)=(.+)$ ]]; then
        VAR="${BASH_REMATCH[1]}"
        VAL="${BASH_REMATCH[2]}"
        VAL="${VAL%\"}" ; VAL="${VAL#\"}"
        VAL="${VAL%\'}" ; VAL="${VAL#\'}"
        if [[ "$VAL" == /* ]] && [[ ! -e "$VAL" ]]; then
            echo "  [WARN] $VAR = $VAL  ← PATH NOT FOUND"
            SETUP_ERRORS=$((SETUP_ERRORS + 1))
        else
            [[ "$VAL" == /* ]] && echo "  [OK]  $VAR = $VAL"
        fi
    fi
done < "$SETUP_SCRIPT"

if [[ $SETUP_ERRORS -gt 0 ]]; then
    echo ""
    echo "  ERROR: $SETUP_ERRORS missing path(s) in SetUpHCPPipeline.sh."
    echo "  Edit $SETUP_SCRIPT and fix the paths above before running HCP."
    exit 1
fi
echo "  All paths in SetUpHCPPipeline.sh look valid."

# ── Locate T1w / T2w — require run-01 if multiple runs exist ─────────────────
ANAT_DIR="$SUB_BIDS_DIR/anat"
[[ -n "${SESSION_ID:-}" ]] && ANAT_DIR="$SUB_BIDS_DIR/ses-${SESSION_ID}/anat"

[[ -d "$ANAT_DIR" ]] || { echo "ERROR: Anat folder not found at $ANAT_DIR"; exit 1; }

resolve_anat() {
    local suffix="$1"   # T1w or T2w

    # Count how many NIfTI files exist for this suffix
    mapfile -t all_files < <(
        find "$ANAT_DIR" -maxdepth 1 -name "*_${suffix}.nii.gz" 2>/dev/null | sort
    )
    local n="${#all_files[@]}"

    if [[ "$n" -eq 0 ]]; then
        echo ""   # caller checks for empty string
        return
    fi

    if [[ "$n" -eq 1 ]]; then
        # Only one file — use it regardless of run label
        echo "${all_files[0]}"
        return
    fi

    # More than one — require run-01
    local run01
    run01=$(printf '%s\n' "${all_files[@]}" | grep -E '_run-01_'"${suffix}"'\.nii\.gz$' | head -1)

    if [[ -n "$run01" ]]; then
        echo "$run01"
    else
        echo ""   # signal not found
    fi
}

echo "  Resolving T1w..."
SRC_T1=$(resolve_anat "T1w")
if [[ -z "$SRC_T1" ]]; then
    mapfile -t t1_all < <(find "$ANAT_DIR" -maxdepth 1 -name "*_T1w.nii.gz" 2>/dev/null | sort)
    if [[ "${#t1_all[@]}" -gt 1 ]]; then
        echo "  ERROR: Multiple T1w files found but none has 'run-01' in the filename."
        echo "         Found:"
        printf '           %s\n' "${t1_all[@]}"
        echo "         HCP requires exactly one T1w. Rename the intended file to include"
        echo "         'run-01' or remove the extra files before running this step."
        exit 1
    else
        echo "  ERROR: No T1w file found in $ANAT_DIR"
        exit 1
    fi
fi
echo "    Using T1w: $(basename "$SRC_T1")"

echo "  Resolving T2w..."
SRC_T2=$(resolve_anat "T2w")
if [[ -z "$SRC_T2" ]]; then
    mapfile -t t2_all < <(find "$ANAT_DIR" -maxdepth 1 -name "*_T2w.nii.gz" 2>/dev/null | sort)
    if [[ "${#t2_all[@]}" -gt 1 ]]; then
        echo "  WARNING: Multiple T2w files found but none has 'run-01' in the filename."
        echo "           Found:"
        printf '             %s\n' "${t2_all[@]}"
        echo "           HCP will run T1w-only (lower quality surface)."
    else
        echo "  WARNING: No T2w file found — HCP will run T1w-only (lower quality surface)."
    fi
fi
[[ -n "$SRC_T2" ]] && echo "    Using T2w: $(basename "$SRC_T2")"

# ── Arrange into HCP unprocessed structure ────────────────────────────────────
HCP_STUDY="$HCP_OUTPUT_DIR"
T1W_DIR="$HCP_STUDY/$SUBJECT_ID/unprocessed/3T/T1w_MPR1"
T2W_DIR="$HCP_STUDY/$SUBJECT_ID/unprocessed/3T/T2w_SPC1"
mkdir -p "$T1W_DIR" "$T2W_DIR"

T1W_DEST="$T1W_DIR/${SUBJECT_ID}_3T_T1w_MPR1.nii.gz"
T2W_DEST="$T2W_DIR/${SUBJECT_ID}_3T_T2w_SPC1.nii.gz"

echo "  Staging T1w → $T1W_DEST"
cp -n "$SRC_T1" "$T1W_DEST"

if [[ -n "$SRC_T2" ]]; then
    echo "  Staging T2w → $T2W_DEST"
    cp -n "$SRC_T2" "$T2W_DEST"
fi

echo "  HCP unprocessed layout:"
find "$HCP_STUDY/$SUBJECT_ID/unprocessed" -name "*.nii.gz" | sort | sed 's/^/    /'

# ── Source HCP env ────────────────────────────────────────────────────────────
source "$SETUP_SCRIPT"

# ── cd to hcp_logs so .o/.e job files land there, not in PIPELINE_BASE ────────
mkdir -p "$WORK_DIR/hcp_processing/hcp_logs"
cd "$WORK_DIR/hcp_processing/hcp_logs"
echo "  HCP job files (.o/.e) will be written to: $WORK_DIR/hcp_processing/hcp_logs"

# ── Stage marker — records which sub-stage was last attempted ────────────────
# If this step gets interrupted mid-stage, this file tells a human (or a
# future automated check) exactly which of the three sub-stages was in
# flight, without having to grep timestamps across .o/.e files.
STAGE_MARKER="$WORK_DIR/hcp_processing/hcp_logs/.current_stage"

# ── Run HCP stages ────────────────────────────────────────────────────────────
for STAGE in PreFreeSurfer FreeSurfer PostFreeSurfer; do
    echo ""
    echo "  ── HCP $STAGE ──────────────────────────────"
    echo "$STAGE" > "$STAGE_MARKER"

    # Record the time just before launching this stage, and clear out any
    # .o/.e files already matching this stage name from a previous attempt.
    # Without this, a crash that never produces a NEW .o file would let the
    # "find latest .o file" check below silently pick up a STALE file from a
    # prior run and misreport success.
    find "$WORK_DIR/hcp_processing/hcp_logs" -maxdepth 1 -iname "*${STAGE}*.o*" -delete 2>/dev/null || true
    find "$WORK_DIR/hcp_processing/hcp_logs" -maxdepth 1 -iname "*${STAGE}*.e*" -delete 2>/dev/null || true

    "$HCPPIPEDIR/Examples/Scripts/${STAGE}PipelineBatch.sh" \
        --StudyFolder="$HCP_STUDY" \
        --Subject="$SUBJECT_ID"

    # Find the latest .o file for this stage
    OUT_FILE=$(find "$WORK_DIR/hcp_processing/hcp_logs" \
        -type f \
        -iname "*${STAGE}*.o*" \
        -printf "%T@ %p\n" | sort -nr | head -1 | cut -d' ' -f2-)

    # Check if a log file exists and if it contains "completed"
    if [[ -n "$OUT_FILE" ]]; then
        if grep -qi "completed" "$OUT_FILE"; then
            echo "  $STAGE confirmed as completed."
        else
            echo "  ERROR: $STAGE did not report 'completed' in log file."
            # Optional: Print the last few lines of the error file if it exists
            ERR_FILE=$(find "$WORK_DIR/hcp_processing/hcp_logs" -type f -iname "*${STAGE}*.e*" -printf "%T@ %p\n" | sort -nr | head -1 | cut -d' ' -f2-)
            [[ -f "$ERR_FILE" ]] && tail -n 20 "$ERR_FILE"
            exit 1
        fi
    else
        echo "  WARNING: No .o file found for $STAGE. Manual check required."
        exit 1
    fi
    echo "  $STAGE completed successfully."
done

rm -f "$STAGE_MARKER"
echo "  HCP output: $HCP_STUDY/$SUBJECT_ID"