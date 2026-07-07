#!/usr/bin/env bash
# Step 07 — ASLPrep (arterial spin labeling)
# ASLPrep processes ALL *_asl.nii.gz files under perf/ in one docker call.
# Pre-flight loops over every run to patch JSON sidecars and generate
# aslcontext.tsv files so ASLPrep never chokes on a missing field.
set -euo pipefail

# ── Resolve ASL labeling type from .env (no interactive prompt) ───────────────
# Set ASL_LABELING_TYPE=PCASL (or CASL / PASL) in .env before running.
ASL_LABELING_TYPE="${ASL_LABELING_TYPE:-}"
if [[ -z "$ASL_LABELING_TYPE" ]]; then
    echo "ERROR: ASL_LABELING_TYPE is not set in .env."
    echo "       Add one of the following to .env and re-run:"
    echo "         ASL_LABELING_TYPE=PCASL   (pseudo-continuous ASL — most common)"
    echo "         ASL_LABELING_TYPE=CASL    (continuous ASL)"
    echo "         ASL_LABELING_TYPE=PASL    (pulsed ASL)"
    exit 1
fi

ASL_LABELING_TYPE="${ASL_LABELING_TYPE^^}"   # normalise to uppercase
if [[ ! "$ASL_LABELING_TYPE" =~ ^(PCASL|CASL|PASL)$ ]]; then
    echo "ERROR: ASL_LABELING_TYPE='$ASL_LABELING_TYPE' is invalid."
    echo "       Must be PCASL, CASL, or PASL."
    exit 1
fi
echo "  ASL labeling type: $ASL_LABELING_TYPE (from .env)"

# ── Find all ASL runs ─────────────────────────────────────────────────────────
mapfile -t ASL_FILES < <(find "$SUB_BIDS_DIR/perf" -name "*_asl.nii.gz" 2>/dev/null | sort)

# ── No-ASL early exit — MUST come before the validation/quarantine logic ────
# Previously this check was AFTER the "no valid files" check, so a subject
# with no ASL acquisition at all (a totally normal, common case — not every
# protocol includes ASL) fell into the "no valid files" branch and hard-FAILED
# instead of cleanly skipping. Order matters here.
if [[ ${#ASL_FILES[@]} -eq 0 ]]; then
    echo "  No ASL data found for $SUB_LABEL — skipping ASLPrep."
    exit 0
fi

# ── Quarantine dir + restore trap ────────────────────────────────────────────
# Registered before any files are moved, so a crash anywhere after this point
# (JSON patch failure, docker run failure, etc.) still restores quarantined
# but otherwise-valid ASL files instead of leaving them stranded.
TMP_ASL_DEL="$SUB_BIDS_DIR/tmp_asl_del"
mkdir -p "$TMP_ASL_DEL"

_restore_asl_quarantined() {
    if [[ -d "$TMP_ASL_DEL" ]] && [[ -n "$(ls -A "$TMP_ASL_DEL" 2>/dev/null)" ]]; then
        echo "  Restoring quarantined ASL files..."
        mv "$TMP_ASL_DEL"/* "$SUB_BIDS_DIR/perf/" 2>/dev/null || true
    fi
    rmdir "$TMP_ASL_DEL" 2>/dev/null || true
}
trap _restore_asl_quarantined EXIT

# ── ASL Pre-flight dataset validation ────────────────────────────────────────
VALID_ASL_FILES=()
BAD_ASL_FILES=()

# Path passed via sys.argv, not string-interpolated into the Python literal —
# a path containing a single quote or other special character would otherwise
# break out of the interpolated string and either error or, worse, execute
# unintended code.
get_asl_dim4() {
    python3 -c "
import sys, nibabel as nib
shape = nib.load(sys.argv[1]).shape
print(shape[3] if len(shape) > 3 else 1)
" "$1" 2>/dev/null || echo "0"
}

echo "  Running ASL validation..."

for f in "${ASL_FILES[@]}"; do
    stem=$(basename "$f")
    dim4=$(get_asl_dim4 "$f")

    if [[ "$dim4" -ge 2 ]]; then
        VALID_ASL_FILES+=("$f")
        echo "    OK  : $stem (dim4=$dim4)"
    else
        BAD_ASL_FILES+=("$f")
        echo "    BAD : $stem (dim4=$dim4) → quarantining"

        mv "$f" "$TMP_ASL_DEL/"

        # also move sidecars
        for ext in json tsv nii.gz; do
            side="${f%.nii.gz}.${ext}"
            [[ -f "$side" ]] && mv "$side" "$TMP_ASL_DEL/"
        done
    fi
done

if [[ ${#VALID_ASL_FILES[@]} -eq 0 ]]; then
    echo "  ERROR: ASL data exists but none passed validation — aborting ASLPrep."
    exit 1
fi

echo "  Found ${#ASL_FILES[@]} ASL run(s) — ASLPrep will process all:"
for f in "${ASL_FILES[@]}"; do echo "    $(basename "$f")"; done

# ── Per-run pre-flight: patch JSON sidecar + generate aslcontext.tsv ─────────
for ASL_FILE in "${VALID_ASL_FILES[@]}"; do
    RUN_STEM=$(basename "${ASL_FILE/_asl.nii.gz/}")
    echo ""
    echo "  ── Pre-flight: $RUN_STEM ──────────────────────────────────────"

    JSON_FILE="${ASL_FILE/_asl.nii.gz/_asl.json}"
    [[ -f "$JSON_FILE" ]] || { echo "ERROR: Sidecar JSON not found: $JSON_FILE"; exit 1; }

    # ── Patch JSON sidecar ────────────────────────────────────────────────────
    echo "  Checking/patching $(basename "$JSON_FILE") ..."
    python3 - "$JSON_FILE" "$ASL_LABELING_TYPE" << 'PYEOF'
import json, os, sys

path        = sys.argv[1]
label_type  = sys.argv[2]   # from .env — already validated in bash

with open(path) as f:
    d = json.load(f)

changed = []

# ArterialSpinLabelingType — use the value from .env
current = d.get("ArterialSpinLabelingType", "").upper()
if current != label_type:
    print(f"  [PATCH] ArterialSpinLabelingType: '{d.get('ArterialSpinLabelingType','missing')}' → '{label_type}'")
    d["ArterialSpinLabelingType"] = label_type
    changed.append("ArterialSpinLabelingType")
else:
    print(f"  [OK]    ArterialSpinLabelingType = {label_type}")

# M0Type
if "M0Type" not in d:
    ctx = path.replace("_asl.json", "_aslcontext.tsv")
    has_m0_vol = False
    if os.path.exists(ctx):
        with open(ctx) as f:
            has_m0_vol = any("m0scan" in line for line in f)
    m0type = "Included" if has_m0_vol else "Estimate"
    print(f"  [PATCH] M0Type missing → '{m0type}' (m0scan in tsv: {has_m0_vol})")
    d["M0Type"] = m0type
    changed.append("M0Type")
    if m0type == "Estimate" and "M0Estimate" not in d:
        d["M0Estimate"] = 1000.0
        changed.append("M0Estimate")
        print(f"  [PATCH] M0Estimate → 1000.0 (placeholder — update if known)")
else:
    print(f"  [OK]    M0Type = {d['M0Type']}")

# BackgroundSuppression
if "BackgroundSuppression" not in d:
    d["BackgroundSuppression"] = False
    changed.append("BackgroundSuppression")
    print(f"  [PATCH] BackgroundSuppression missing → False")
else:
    print(f"  [OK]    BackgroundSuppression = {d['BackgroundSuppression']}")

# PostLabelingDelay
if "PostLabelingDelay" not in d:
    d["PostLabelingDelay"] = 1.8
    changed.append("PostLabelingDelay")
    print(f"  [PATCH] PostLabelingDelay missing → 1.8s (verify against protocol!)")
else:
    print(f"  [OK]    PostLabelingDelay = {d['PostLabelingDelay']}")

# LabelingDuration (PCASL / CASL only)
if label_type in ("PCASL", "CASL") and "LabelingDuration" not in d:
    d["LabelingDuration"] = 1.8
    changed.append("LabelingDuration")
    print(f"  [PATCH] LabelingDuration missing → 1.8s (verify against protocol!)")
elif "LabelingDuration" in d:
    print(f"  [OK]    LabelingDuration = {d['LabelingDuration']}")

if changed:
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
    print(f"  Saved {len(changed)} patch(es) to {os.path.basename(path)}")
    print(f"  ⚠  Review patched values: {', '.join(changed)}")
else:
    print(f"  JSON sidecar OK — no patches needed.")
PYEOF

    # ── Generate aslcontext.tsv if missing ───────────────────────────────────
    CONTEXT_FILE="${ASL_FILE/_asl.nii.gz/_aslcontext.tsv}"

    if [[ -f "$CONTEXT_FILE" ]]; then
        echo "  aslcontext.tsv exists: $(basename "$CONTEXT_FILE")"
    else
        echo "  aslcontext.tsv NOT found — generating from volume count..."

        NVOLS=$(python3 -c "
import sys, nibabel as nib
print(nib.load(sys.argv[1]).shape[3])
" "$ASL_FILE" 2>/dev/null || echo "0")
        [[ "$NVOLS" -gt 0 ]] || { echo "ERROR: Could not read volume count from $ASL_FILE"; exit 1; }
        echo "  Volumes detected: $NVOLS"

        M0TYPE=$(python3 -c "
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get('M0Type', 'Estimate'))
" "$JSON_FILE" 2>/dev/null || echo "Estimate")

        echo "  M0Type found in JSON: $M0TYPE"

        {
            echo "volume_type"
            if [[ "$M0TYPE" == "Included" ]]; then
                # If M0 is included, the last volume is explicitly the m0scan
                PAIR_VOLS=$((NVOLS - 1))
                for ((i=0; i<PAIR_VOLS; i+=2)); do
                    echo "control"
                    echo "label"
                done
                echo "m0scan"
            else
                # For Estimate, there is NO m0scan volume.
                # Strictly loop alternating control/label pairs until NVOLS is reached.
                for ((i=0; i<NVOLS; i+=2)); do
                    echo "control"
                    if (( i + 1 < NVOLS )); then
                        echo "label"
                    fi
                done
            fi
        } > "$CONTEXT_FILE"

        echo "  Successfully created: $(basename "$CONTEXT_FILE")"
        head -6 "$CONTEXT_FILE" | sed 's/^/    /'
        echo "    ... ($(($(wc -l < "$CONTEXT_FILE")-1)) volume rows total)"
    fi

    # ── Validate TSV row count ────────────────────────────────────────────────
    NVOLS=$(python3 -c "
import sys, nibabel as nib
print(nib.load(sys.argv[1]).shape[3])
" "$ASL_FILE" 2>/dev/null || echo "0")
    TSV_ROWS=$(( $(wc -l < "$CONTEXT_FILE") - 1 ))
    if [[ "$TSV_ROWS" -ne "$NVOLS" ]]; then
        echo "ERROR: $(basename "$CONTEXT_FILE") has $TSV_ROWS rows but NIfTI has $NVOLS volumes."
        exit 1
    fi
    echo "  TSV rows match volume count ($NVOLS). ✓"

    # quick sanity check: ensure aslcontext alternates properly
    if grep -q "control" "$CONTEXT_FILE" && grep -q "label" "$CONTEXT_FILE"; then
        :
    else
        echo "ERROR: aslcontext missing control/label structure"
        exit 1
    fi

done  # end per-run loop

# ── FreeSurfer reuse ──────────────────────────────────────────────────────────
FS_DONE="$FS_OUTPUT_DIR/$SUB_LABEL/scripts/recon-all.done"
FS_ARG=""
FS_VOL=""
if [[ -f "$FS_DONE" ]]; then
    echo ""
    echo "  Using existing FreeSurfer output."
    FS_ARG="--fs-subjects-dir /fs_output"
    FS_VOL="-v $FS_OUTPUT_DIR:/fs_output"
else
    echo ""
    echo "  FreeSurfer output not found — ASLPrep will run its own recon (slower)."
fi

# ── Run ASLPrep (processes ALL ASL runs in one call) ─────────────────────────
docker run --rm \
    -v "$SUB_BIDS_DIR:/data:ro" \
    -v "$ASLPREP_OUT:/out" \
    -v "$FS_LICENSE:/license:ro" \
    -v "$WORKING_DIR:/work" \
    $FS_VOL \
    "$ASLPREP_IMAGE" \
    /data /out participant \
    --participant-label "$SUBJECT_ID" \
    --fs-license-file /license \
    --nprocs "$N_THREADS" \
    --mem "$MEM_GB" \
    --work-dir /work \
    --skip-bids-validation \
    $FS_ARG

echo "  ASLPrep output: $ASLPREP_OUT"
echo "  Restore of quarantined ASL files will happen automatically on exit."