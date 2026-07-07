#!/usr/bin/env bash
# Step 03 — FreeSurfer recon-all (Docker)
# Output reused by fMRIPrep, ASLPrep via --fs-subjects-dir
set -euo pipefail

# ── Resolve anat dir, session-aware ──────────────────────────────────────────
# Previously this always looked at $SUB_BIDS_DIR/anat/, which silently finds
# zero T1w files for any session-organized (ses-XX) BIDS dataset. 04_hcp_preproc.sh
# already handles this; mirror the same logic here for consistency across labs
# that may or may not use sessions.
ANAT_DIR="$SUB_BIDS_DIR/anat"
[[ -n "${SESSION_ID:-}" ]] && ANAT_DIR="$SUB_BIDS_DIR/ses-${SESSION_ID}/anat"

# ── Completion checker ────────────────────────────────────────────────────────
# Uses three signals, all must pass:
#   1. recon-all.done file exists (FreeSurfer's own flag)
#   2. recon-all.log contains "finished without error" (log confirmation)
#   3. Critical output files are present (surface + parcellation)
is_freesurfer_complete() {
    local subj_dir="$1"

    # Signal 1: recon-all.done
    if [[ ! -f "$subj_dir/scripts/recon-all.done" ]]; then
        echo "  [CHECK] recon-all.done not found — incomplete."
        return 1
    fi

    # Signal 2: log says finished without error
    if ! grep -q "finished without error" "$subj_dir/scripts/recon-all.log" 2>/dev/null; then
        echo "  [CHECK] recon-all.log does not confirm clean finish — incomplete."
        return 1
    fi

    # Signal 3: critical output files
    local required_files=(
        "mri/aseg.mgz"
        "mri/aparc+aseg.mgz"
        "surf/lh.pial"
        "surf/rh.pial"
        "surf/lh.white"
        "surf/rh.white"
        "surf/lh.thickness"
        "surf/rh.thickness"
        "label/lh.aparc.annot"
        "label/rh.aparc.annot"
    )
    for f in "${required_files[@]}"; do
        if [[ ! -f "$subj_dir/$f" ]]; then
            echo "  [CHECK] Missing critical file: $f — incomplete."
            return 1
        fi
    done

    return 0
}

# ── Run recon-all for one T1w file ───────────────────────────────────────────
# Args: $1 = T1w nii.gz path, $2 = output dir, $3 = subject label, $4 = run label (for logging)
run_recon() {
    local t1_file="$1"
    local out_dir="$2"
    local sub_label="$3"
    local run_label="$4"

    local subj_dir="$out_dir/$sub_label"
    mkdir -p "$out_dir"

    # ── Completion check ──────────────────────────────────────────────────────
    if [[ -d "$subj_dir" ]]; then
        if is_freesurfer_complete "$subj_dir"; then
            echo "  [DONE] FreeSurfer genuinely complete for $sub_label ($run_label) — skipping."
            return 0
        else
            echo "  [RESUME] Output exists but failed completion checks for $sub_label ($run_label) — archiving and re-running."
            mv "$subj_dir" "${subj_dir}_failed_$(date +%Y%m%d_%H%M%S)"
        fi
    else
        echo "  [FRESH] No existing output for $sub_label ($run_label) — starting recon-all from scratch."
    fi

    # ── Execute recon-all ─────────────────────────────────────────────────────
    # Note: -i path uses ANAT_DIR (session-aware), and we mount ANAT_DIR's
    # parent ($SUB_BIDS_DIR or $SUB_BIDS_DIR/ses-X) as /input so the relative
    # path inside the container still resolves correctly.
    echo "  Running recon-all for $(basename "$t1_file") → $out_dir"
    docker run --rm \
        -v "$SUB_BIDS_DIR:/input:ro" \
        -v "$out_dir:/output" \
        -v "$FS_LICENSE:/usr/local/freesurfer/license.txt:ro" \
        "${FREESURFER_IMAGE:-freesurfer/freesurfer:7.4.1}" \
        recon-all \
        -i "/input${t1_file#"$SUB_BIDS_DIR"}" \
        -s "$sub_label" \
        -sd /output \
        -all

    # ── Post-run verification ─────────────────────────────────────────────────
    if is_freesurfer_complete "$subj_dir"; then
        echo "  [✓] FreeSurfer completion verified for $sub_label ($run_label)."
    else
        echo "  [ERROR] FreeSurfer finished but failed completion checks for $sub_label ($run_label)."
        echo "          Check $subj_dir/scripts/recon-all.log for errors."
        exit 1
    fi
}

# ── Find T1w files ────────────────────────────────────────────────────────────
[[ -d "$ANAT_DIR" ]] || { echo "  [ERROR] Anat folder not found at $ANAT_DIR"; exit 1; }

mapfile -t T1W_FILES < <(find "$ANAT_DIR" -maxdepth 1 -type f -name "*T1w*.nii.gz" | sort)
file_count="${#T1W_FILES[@]}"
echo "  Total T1w files found: $file_count (in $ANAT_DIR)"

if [[ "$file_count" -eq 0 ]]; then
    echo "  [ERROR] No T1w files found in $ANAT_DIR — aborting."
    exit 1
fi

# ── Process each T1w ─────────────────────────────────────────────────────────
OVERALL_FAILED=0

for i in "${!T1W_FILES[@]}"; do
    f="${T1W_FILES[$i]}"
    run_num=$((i + 1))

    if [[ "$run_num" -eq 1 ]]; then
        # Primary run — output goes directly into FS_OUTPUT_DIR
        run_recon "$f" "$FS_OUTPUT_DIR" "$SUB_LABEL" "run_1" || OVERALL_FAILED=1
    else
        # Additional runs — each gets its own subfolder: FS_OUTPUT_DIR/run_N/
        run_recon "$f" "$FS_OUTPUT_DIR/run_${run_num}" "$SUB_LABEL" "run_${run_num}" || OVERALL_FAILED=1
    fi
done

# ── Final exit ────────────────────────────────────────────────────────────────
if [[ "$OVERALL_FAILED" -eq 1 ]]; then
    echo "  [ERROR] One or more FreeSurfer runs failed."
    exit 1
fi

echo "  [✓] All FreeSurfer runs completed successfully."