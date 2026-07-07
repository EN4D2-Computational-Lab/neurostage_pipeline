#!/usr/bin/env bash
# Step 02 — MRIQC
set -euo pipefail
PY_CHECK="$PIPELINE_BASE/scripts/check_important_file_in_bids.py"
if [[ -f "$PY_CHECK" ]]; then
    echo "  Creating a bids-filter-sub{}.json file at: $OUTPUT_BASE ..."
    python3 "$PY_CHECK" "$SUB_BIDS_DIR" --output "$OUTPUT_BASE"
fi
docker run --rm \
    -v "$BIDS_DIR:/data:ro" \
    -v "$MRIQC_OUT:/out" \
    -v "$OUTPUT_BASE/bids_filter_sub-${SUBJECT_ID}.json:/filter.json:ro" \
    "$MRIQC_IMAGE" \
    /data /out participant \
    --participant-label "$SUBJECT_ID" \
    --nprocs "$N_THREADS" \
    --bids-filter-file /filter.json \
    --mem_gb "$MEM_GB" \
    --no-sub
echo "  MRIQC output: $MRIQC_OUT"
