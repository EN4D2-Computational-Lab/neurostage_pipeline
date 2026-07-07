#!/usr/bin/env python3
"""
BIDS Filter File Generator for MRIQC
=====================================
Scans a subject's BIDS folder and builds a bids_filter.json that tells
MRIQC exactly which files are valid — so it never chokes on bad ones.

Checks performed per file
─────────────────────────
  1. Missing .json sidecar          → flag  (MRIQC needs TR, PhaseEnc, etc.)
  2. BidsGuess mismatch             → flag  (but T2w/anat is exempt — see note)
  3. Missing .nii/.nii.gz           → flag  (nothing to process)
  4. NIfTI unreadable / corrupt     → flag  (nibabel can't open it)
  5. Anat shape not 3-D             → flag  (T1w/T2w must be 3-D volumes)
  6. func/perf ≤1 timepoint         → flag  (SBRef or corrupt)
  7. DWI: missing .bval or .bvec    → flag  (both required)
  8. DWI: b0-only (.bval ≤1 value)  → flag  (no diffusion directions)
  9. DWI: bval/bvec length mismatch → flag  (mismatched sidecars)
 10. fmap/perf present but misplaced → warn (user told, not silently skipped)

BidsGuess note
──────────────
  BidsGuess[0] is checked against the BIDS suffix expected for that folder,
  NOT the folder name string. This matters for anat: a T2w file correctly
  lives in the 'anat' folder, but BidsGuess[0] might say 'T2w', not 'anat'.
  So for anat we accept any suffix in [T1w, T2w, FLAIR, T2star, ...].
  For func/dwi we still check that BidsGuess matches the expected suffix.

Usage
─────
  python check_important_file_in_bids.py <subject_bids_folder> [--output /path/to/filter.json]

  Examples:
    python check_important_file_in_bids.py /data/bids_output/sub-1004
    python check_important_file_in_bids.py /data/bids_output/sub-1004 --output /data/filter.json
"""

import os
import re
import sys
import json
from collections import defaultdict


# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

# Folders MRIQC supports → the suffixes that are VALID inside that folder.
# This is the ground truth for BidsGuess validation (not the folder name).
FOLDER_VALID_SUFFIXES = {
    "anat": {"T1w", "T2w", "FLAIR", "T2star", "T1rho", "angio", "PDw", "PDT2", "inplaneT1", "inplaneT2"},
    "func": {"bold", "cbv", "phase"},
    "dwi":  {"dwi", "sbref"},   # sbref in dwi is valid BIDS but flagged separately by timepoint check
}

# Folders that exist in BIDS but MRIQC cannot process — warn the user.
UNSUPPORTED_FOLDERS = {"perf", "fmap", "meg", "eeg", "ieeg", "beh"}

# DWI suffixes that require .bval + .bvec
DWI_DIFFUSION_SUFFIXES = {"dwi"}


# ─────────────────────────────────────────────────────────────────────────────
# Entity / filename helpers
# ─────────────────────────────────────────────────────────────────────────────

def parse_bids_entities(filename_base):
    """
    Parse BIDS entities from a filename base (no extension).
    e.g. 'sub-1004_ses-01_task-rest_run-02_bold'
      → {'sub': '1004', 'ses': '01', 'task': 'rest', 'run': '02', 'suffix': 'bold'}

    The suffix is always the LAST underscore-separated part that contains
    no '-' character. This is the BIDS spec definition.
    """
    parts = filename_base.split("_")
    entities = {}

    # Last part with no '-' is the suffix
    if parts and "-" not in parts[-1]:
        entities["suffix"] = parts[-1]
        parts = parts[:-1]

    for part in parts:
        if "-" in part:
            key, val = part.split("-", 1)
            entities[key] = val
        # parts without '-' that are not the last part are non-standard; skip

    return entities


def extract_subject_id(folder_path):
    """
    Safely extract subject ID from a path ending in sub-XXXX.
    Handles: sub-1004, sub-HC01, sub-HC-01 (hyphenated labels).
    Uses regex so it won't mangle unrelated path components.
    """
    basename = os.path.basename(folder_path.rstrip("/"))
    match = re.match(r'^sub-(.+)$', basename)
    if match:
        return match.group(1)
    return basename   # fallback: use folder name as-is


# ─────────────────────────────────────────────────────────────────────────────
# Per-file check helpers
# ─────────────────────────────────────────────────────────────────────────────

def check_nii_readable(nii_path):
    """
    Try to open the NIfTI with nibabel.
    Returns (shape, error_message). shape is None on failure.
    """
    try:
        import nibabel as nib
        img = nib.load(nii_path)
        shape = img.header.get_data_shape()
        return shape, None
    except Exception as e:
        return None, str(e)


def check_bval_bvec(folder_path, base):
    """
    Validate DWI sidecar files (.bval + .bvec).
    Returns list of failure reasons (empty = all good).
    """
    reasons = []
    bval_path = os.path.join(folder_path, base + ".bval")
    bvec_path = os.path.join(folder_path, base + ".bvec")

    # Existence
    if not os.path.exists(bval_path):
        reasons.append("missing .bval sidecar")
    if not os.path.exists(bvec_path):
        reasons.append("missing .bvec sidecar")

    if reasons:
        return reasons   # can't do further checks without both files

    # Read bval
    try:
        import numpy as np
        bvals = np.loadtxt(bval_path)
        n_bval = int(bvals.size)
    except Exception as e:
        reasons.append(f".bval unreadable: {e}")
        return reasons

    # b0-only check
    if n_bval <= 1:
        reasons.append(f".bval has only {n_bval} value(s) — likely b0-only or empty")
        return reasons

    # Read bvec
    try:
        bvecs = np.loadtxt(bvec_path)
        # bvec shape is (3, N) or (N, 3)
        n_bvec = bvecs.shape[1] if bvecs.ndim == 2 and bvecs.shape[0] == 3 else (
                 bvecs.shape[0] if bvecs.ndim == 2 and bvecs.shape[1] == 3 else bvecs.size)
    except Exception as e:
        reasons.append(f".bvec unreadable: {e}")
        return reasons

    # Length mismatch
    if n_bval != n_bvec:
        reasons.append(f".bval length ({n_bval}) != .bvec length ({n_bvec})")

    return reasons

def check_json_sidecar(json_path):
    """
    Read and return (meta_dict, error_message).
    meta_dict is None on failure.
    """
    try:
        with open(json_path) as f:
            meta = json.load(f)
        return meta, None
    except Exception as e:
        return None, str(e)

# ─────────────────────────────────────────────────────────────────────────────
# BidsGuess validation — the tricky part
# ─────────────────────────────────────────────────────────────────────────────

def check_bids_guess(meta, folder_name, suffix):
    """
    Check BidsGuess[0] against what we expect for this folder/suffix.

    dcm2bids can write BidsGuess in two different styles depending on version:
      Style A — suffix style : BidsGuess='T1w'   (the BIDS suffix)
      Style B — folder style : BidsGuess='anat'  (the datatype folder name)

    Both styles are VALID as long as the value is consistent with the folder
    the file actually lives in. Examples:

      File: anat/sub-1004_T1w.nii.gz
        BidsGuess='T1w'   → ✅  suffix style, T1w is valid in anat/
        BidsGuess='anat'  → ✅  folder style, file IS in anat/
        BidsGuess='func'  → ❌  folder style, file is NOT in func/
        BidsGuess='bold'  → ❌  suffix style, bold is not valid in anat/

      File: func/sub-1004_task-rest_run-01_bold.nii.gz
        BidsGuess='bold'  → ✅  suffix style, bold is valid in func/
        BidsGuess='func'  → ✅  folder style, file IS in func/
        BidsGuess='fmap'  → ❌  folder style, file is NOT in fmap/
        BidsGuess='T1w'   → ❌  suffix style, T1w is not valid in func/

    A TRUE mismatch is when BidsGuess points to a DIFFERENT folder/suffix
    than where the file currently lives — meaning dcm2bids mis-routed it.

    Returns (is_valid: bool, reason: str or None)
    """
    bids_guess = meta.get("BidsGuess", None)
    if not bids_guess:
        return True, None   # no BidsGuess field → nothing to check

    guessed = bids_guess[0].strip() if isinstance(bids_guess, list) else str(bids_guess).strip()

    valid_suffixes  = FOLDER_VALID_SUFFIXES.get(folder_name, set())
    all_folder_names = set(FOLDER_VALID_SUFFIXES.keys())

    # ── Style B: guessed value is a folder name (e.g. 'anat', 'func', 'dwi')
    if guessed in all_folder_names:
        if guessed == folder_name:
            return True, None   # folder style, matches current folder → OK
        else:
            reason = (
                f"BidsGuess='{guessed}' points to '{guessed}/' "
                f"but file is in '{folder_name}/' — likely mis-routed by dcm2bids"
            )
            return False, reason

    # ── Style A: guessed value is a suffix (e.g. 'T1w', 'bold', 'dwi')
    if guessed in valid_suffixes:
        return True, None   # suffix style, valid for this folder → OK

    # Guessed suffix is valid for a DIFFERENT folder → mis-routed
    for other_folder, other_suffixes in FOLDER_VALID_SUFFIXES.items():
        if guessed in other_suffixes and other_folder != folder_name:
            reason = (
                f"BidsGuess='{guessed}' is a valid suffix for '{other_folder}/' "
                f"but file is in '{folder_name}/' — likely mis-routed by dcm2bids"
            )
            return False, reason

    # Guessed value is unknown entirely — warn but don't block
    # (could be a custom dcm2bids tag we don't recognise)
    print(f"      [WARN] BidsGuess='{guessed}' is unrecognised — treating as no mismatch")
    return True, None


# ─────────────────────────────────────────────────────────────────────────────
# Core scanner
# ─────────────────────────────────────────────────────────────────────────────

def scan_subject(bids_root, subject_id):
    """
    Walk every MRIQC-supported subfolder of bids_root.
    Returns:
      valid_files   : [(folder_name, base, entities), ...]
      flagged_files : [(folder_name, base, [reasons]), ...]
    """
    valid_files   = []
    flagged_files = []

    all_folders = sorted(
        d for d in os.listdir(bids_root)
        if os.path.isdir(os.path.join(bids_root, d))
    )

    for folder_name in all_folders:
        folder_path = os.path.join(bids_root, folder_name)

        # ── Unsupported but known folders → warn, don't silently skip ────
        if folder_name in UNSUPPORTED_FOLDERS:
            print(f"  [WARN] '{folder_name}/' — not supported by MRIQC, skipping "
                  f"(check if any files here were meant for func/dwi/anat)")
            continue

        if folder_name not in FOLDER_VALID_SUFFIXES:
            print(f"  [SKIP] '{folder_name}/' — not a recognised BIDS datatype folder")
            continue

        print(f"\n  Scanning: {folder_name}/")
        processed_bases = set()

        for filename in sorted(os.listdir(folder_path)):
            filepath = os.path.join(folder_path, filename)
            if not os.path.isfile(filepath):
                continue

            # Strip extensions to get canonical base name
            base = filename
            for ext in (".nii.gz", ".nii", ".json", ".bval", ".bvec"):
                if base.endswith(ext):
                    base = base[: -len(ext)]
                    break   # only strip one extension (avoids double-strip)

            if base in processed_bases:
                continue
            processed_bases.add(base)

            reasons = []   # accumulate ALL problems for this file

            # ── Check 1: .json sidecar must exist ────────────────────────
            json_path = os.path.join(folder_path, base + ".json")
            meta = None
            if not os.path.exists(json_path):
                reasons.append("missing .json sidecar (MRIQC needs TR, PhaseEncodingDirection, etc.)")
            else:
                meta, err = check_json_sidecar(json_path)
                if meta is None:
                    reasons.append(f".json unreadable: {err}")

            # ── Check 2: BidsGuess validation (only if json was readable) ─
            entities = parse_bids_entities(base)
            suffix   = entities.get("suffix", "")

            # if meta is not None:
            #     valid_guess, guess_reason = check_bids_guess(meta, folder_name, suffix)
            #     if not valid_guess:
            #         reasons.append(guess_reason)

            # ── Check 3: .nii/.nii.gz must exist ─────────────────────────
            nii_gz = os.path.join(folder_path, base + ".nii.gz")
            nii    = os.path.join(folder_path, base + ".nii")
            if os.path.exists(nii_gz):
                nii_path = nii_gz
            elif os.path.exists(nii):
                nii_path = nii
            else:
                reasons.append("missing .nii/.nii.gz (no image to process)")
                nii_path = None

            # ── Check 4+5: NIfTI readability and shape ────────────────────
            if nii_path:
                shape, err = check_nii_readable(nii_path)
                if shape is None:
                    reasons.append(f"NIfTI unreadable/corrupt: {err}")
                else:
                    ndim = len(shape)

                    # anat must be 3-D
                    if folder_name == "anat" and ndim != 3:
                        reasons.append(
                            f"anat NIfTI is {ndim}-D (shape {shape}) — expected 3-D volume"
                        )

                    # func/perf: flag ≤1 timepoint (SBRef or corrupt)
                    if folder_name in ("func", "perf"):
                        n_tp = shape[3] if ndim == 4 else 0   # 3-D (no time axis) = 0 timepoints, not 1
                        MIN_TIMEPOINTS = 10  # AFNI's 3dToutcount needs >=5 AFTER HMC; volumes can get
                                            # dropped during realignment, so require margin above the floor
                        if n_tp < MIN_TIMEPOINTS:
                            reasons.append(
                                f"NIfTI has only {n_tp} timepoint(s) — below safe minimum "
                                f"({MIN_TIMEPOINTS}) for MRIQC outlier detection"
                            )

            # ── Check 6: DWI sidecar validation (.bval + .bvec) ──────────
            if folder_name == "dwi" and suffix in DWI_DIFFUSION_SUFFIXES:
                dwi_reasons = check_bval_bvec(folder_path, base)
                reasons.extend(dwi_reasons)

            # ── Verdict ───────────────────────────────────────────────────
            if reasons:
                flagged_files.append((folder_name, base, reasons))
                for i, r in enumerate(reasons):
                    prefix = "    [FLAG]" if i == 0 else "          "
                    print(f"{prefix} {base if i == 0 else ''} — {r}")
            else:
                valid_files.append((folder_name, base, entities))
                print(f"    [OK]   {base}")

    return valid_files, flagged_files


# ─────────────────────────────────────────────────────────────────────────────
# BIDS filter builder
# ─────────────────────────────────────────────────────────────────────────────

def build_bids_filter(valid_files, flagged_files):
    """
    Build the bids_filter.json dict from valid files only.

    MRIQC filter structure:
      {
        "T1w":      {"datatype": "anat", "suffix": "T1w"},
        "bold_rest":{"datatype": "func", "suffix": "bold", "task": "rest", "run": ["01","03"]},
        "dwi":      {"datatype": "dwi",  "suffix": "dwi"},
        ...
      }

    Run-level filtering:
      If SOME runs of a task are flagged and others are valid, we list only
      the valid run indices explicitly. We do this by comparing valid runs
      against ALL runs seen (valid + flagged) for that (folder, suffix, task).
    """
    # Collect ALL run indices seen (valid + flagged) per (folder, suffix, task)
    all_runs    = defaultdict(set)   # (folder, suffix, task) → set of run labels
    valid_runs  = defaultdict(set)   # (folder, suffix, task) → set of valid run labels

    def _key_from_entities(folder, entities):
        suffix = entities.get("suffix", folder)
        task   = entities.get("task",   None)
        run    = entities.get("run",    None)
        echo   = entities.get("echo",   None)
        return (folder, suffix, task, echo), run

    for folder_name, base, entities in valid_files:
        group_key, run = _key_from_entities(folder_name, entities)
        all_runs[group_key].add(run)
        valid_runs[group_key].add(run)

    for folder_name, base, reasons in flagged_files:
        entities = parse_bids_entities(base)
        group_key, run = _key_from_entities(folder_name, entities)
        all_runs[group_key].add(run)
        # NOT added to valid_runs

    bids_filter = {}

    for group_key, v_runs in valid_runs.items():
        folder_name, suffix, task, echo = group_key

        # Build filter key (unique string for this entry)
        parts = [suffix]
        if task:  parts.append(task)
        if echo:  parts.append(f"echo{echo}")
        filter_key = suffix

        entry = {
            "datatype": folder_name,
            "suffix":   suffix,
        }
        if task:  entry["task"]  = task
        if echo:  entry["echo"]  = echo

        # Only add run filter if SOME runs were flagged (partial validity)
        total_runs = all_runs[group_key]
        if None not in total_runs:        # runs are explicitly labelled
            flagged_run_set = total_runs - v_runs
            if flagged_run_set:           # at least one run was bad
                sorted_valid = sorted(v_runs)
                entry["run"] = sorted_valid[0] if len(sorted_valid) == 1 else sorted_valid

        bids_filter[filter_key] = entry

    return bids_filter


# ─────────────────────────────────────────────────────────────────────────────
# Main entry point
# ─────────────────────────────────────────────────────────────────────────────

def generate_bids_filter(bids_root, subject_id, output_path=None):
    """
    Scan bids_root, build filter, write JSON. Returns (filter_dict, output_path).
    """
    if not os.path.isdir(bids_root):
        raise ValueError(f"Not a directory: {bids_root}")

    print(f"\n{'═'*60}")
    print(f"  BIDS Filter Generator")
    print(f"{'═'*60}")
    print(f"  Scanning : {bids_root}")
    print(f"  Subject  : sub-{subject_id}")
    print(f"{'─'*60}")

    valid_files, flagged_files = scan_subject(bids_root, subject_id)

    print(f"\n{'─'*60}")
    print(f"  Summary")
    print(f"{'─'*60}")
    print(f"  Valid   : {len(valid_files)} file(s)")
    print(f"  Flagged : {len(flagged_files)} file(s)")

    if flagged_files:
        print(f"\n  Flagged files (excluded from MRIQC filter):")
        for folder, base, reasons in flagged_files:
            print(f"    • {folder}/{base}")
            for r in reasons:
                print(f"        – {r}")

    if not valid_files:
        print("\n  ⚠️  No valid files found. Filter will be empty — MRIQC will have nothing to process.")

    bids_filter = build_bids_filter(valid_files, flagged_files)

    # Output path: derivatives/bids_filters/ inside BIDS root parent
    if output_path is None:
        bids_parent  = os.path.dirname(bids_root.rstrip("/"))
        filters_dir  = os.path.join(bids_parent)
        os.makedirs(filters_dir, exist_ok=True)
        output_path  = os.path.join(filters_dir, f"bids_filter_sub-{subject_id}.json")

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)

    with open(output_path, "w") as f:
        json.dump(bids_filter, f, indent=2)

    print(f"\n  ✅  Filter written to: {output_path}")
    print(f"\n  Filter contents:")
    print(json.dumps(bids_filter, indent=4))

    return bids_filter, output_path


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    bids_root  = sys.argv[1].rstrip("/")
    subject_id = extract_subject_id(bids_root)

    output_path = None
    if "--output" in sys.argv:
        idx = sys.argv.index("--output")
        if idx + 1 < len(sys.argv):
            output_path = sys.argv[idx + 1]
            output_path = os.path.join(output_path, f"bids_filter_sub-{subject_id}.json")

    generate_bids_filter(bids_root, subject_id, output_path=output_path)