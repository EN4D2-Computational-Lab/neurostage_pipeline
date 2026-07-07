#!/usr/bin/env bash
# Step 01 — DICOM → BIDS conversion (handles flat folder, nested, or .zip)
set -euo pipefail

WORK_DICOM="$OUTPUT_BASE/tmp_dicom_${SUBJECT_ID}"
mkdir -p "$WORK_DICOM"

# ── Unzip if needed ──────────────────────────────────────────────────────────
if [[ "$DICOM_INPUT" == *.zip ]]; then
    echo "  Extracting zip: $DICOM_INPUT"
    unzip -q "$DICOM_INPUT" -d "$WORK_DICOM"
    DICOM_SRC="$WORK_DICOM"
else
    DICOM_SRC="$DICOM_INPUT"
fi

# ── Run dcm2bids ─────────────────────────────────────────────────────────────
CMD_ARGS="-d $DICOM_SRC -p $SUBJECT_ID -c $DCM2BIDS_CONFIG -o $BIDS_DIR"
[[ -n "${SESSION_ID:-}" ]] && CMD_ARGS="$CMD_ARGS -s $SESSION_ID"

echo "  Running: dcm2bids $CMD_ARGS"
dcm2bids $CMD_ARGS

# ── Write dataset_description.json if missing ────────────────────────────────
DESC="$BIDS_DIR/dataset_description.json"
if [[ ! -f "$DESC" ]]; then
    cat > "$DESC" << 'EOF'
{
  "Name": "NeuroStage Dataset",
  "BIDSVersion": "1.7.0",
  "DatasetType": "raw"
}
EOF
    echo "  Created: $DESC"
fi

cp "$DESC" "$BIDS_DIR/$SUB_LABEL/dataset_description.json"

# ── Write .bidsignore ────────────────────────────────────────────────────────
cat > "$BIDS_DIR/.bidsignore" << 'EOF'
tmp_dcm2bids/
tmp_dicom_*/
*Processing/
HCPpipelines/
configs/
freesurfer/
workbench/
*.log
*.sh.e*
*.sh.o*
EOF

# ── Cleanup tmp dicom extract ────────────────────────────────────────────────
if [[ -d "$WORK_DICOM" ]]; then
    rm -rf "$WORK_DICOM"
    echo "  Cleaned tmp dicom dir."
fi

# ── Cleanup dcm2bids tmp ─────────────────────────────────────────────────────
TMP_DCM="$BIDS_DIR/tmp_dcm2bids"
[[ -d "$TMP_DCM" ]] && rm -rf "$TMP_DCM" && echo "  Cleaned tmp_dcm2bids."

echo "  BIDS output: $SUB_BIDS_DIR"
