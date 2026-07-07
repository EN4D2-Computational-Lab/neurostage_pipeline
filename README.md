# NeuroStage: End-to-End Neuroimaging Pipeline

A fully automated neuroimaging preprocessing pipeline. Provide raw DICOMs and a single config file; the pipeline handles everything from BIDS conversion through surface reconstruction, diffusion MRI, functional MRI, and arterial spin labeling preprocessing — and automatically checks your machine is ready before touching any data.

---

## Table of Contents

1. [What This Pipeline Does](#what-this-pipeline-does)
2. [Folder Structure](#folder-structure)
3. [Prerequisites](#prerequisites)
4. [Quick Start (Recommended)](#quick-start-recommended)
5. [One-Time Setup (Manual)](#one-time-setup-manual)
6. [Configure Your Run (.env)](#configure-your-run-env)
7. [Running the Pipeline](#running-the-pipeline)
8. [Parallel vs Sequential Mode](#parallel-vs-sequential-mode)
9. [How Completion Tracking Works](#how-completion-tracking-works)
10. [Resuming a Failed or Interrupted Run](#resuming-a-failed-or-interrupted-run)
11. [Output Structure](#output-structure)
12. [Troubleshooting](#troubleshooting)
13. [Step Reference](#step-reference)

---

## What This Pipeline Does

| Step | Tool | What it produces |
|------|------|-----------------|
| 01 | dcm2bids | BIDS-formatted dataset from raw DICOMs |
| 02 | MRIQC | Image quality metrics and visual QC reports |
| 03 | FreeSurfer | Structural surface reconstruction (recon-all) |
| 04 | HCP Pipelines | HCP-style structural preprocessing |
| 05 | QSIPrep | Diffusion MRI preprocessing + eddy correction |
| 06 | fMRIPrep | Functional MRI preprocessing |
| 07 | ASLPrep | Arterial spin labeling (perfusion) preprocessing |

**Stage 1** (Steps 02–04) runs first. **Stage 2** (Steps 05–07) waits for Stage 1 to fully complete before starting, because fMRIPrep and ASLPrep reuse the FreeSurfer surfaces produced in Step 03.

---

## Folder Structure

FreeSurfer, FSL, HCP Pipelines, and Workbench are **not shipped inside the git repo** — cloning it gives you orchestration code only. The first time you run `run_pipeline.sh`, it notices these tools aren't installed yet and calls `install_dependencies.sh` for you automatically, which downloads and installs the exact pinned versions straight into `PIPELINE_BASE`. Nothing to build or configure by hand, and nothing to re-clone. The pipeline resolves all tool paths automatically from the single `PIPELINE_BASE` variable you set in `.env`.

```
neurostage_pipeline/
│
├── run_pipeline.sh              ← main entry point — run this
├── install_dependencies.sh      ← runs automatically on first launch — installs
│                                   FreeSurfer, FSL, HCPPipelines, Workbench for you
├── .env.template                ← copy to .env, fill in 3 fields
├── .env                         ← your config (never commit this to git)
├── dcm2bids_config.json         ← BIDS sequence mapping (pre-configured)
├── dataset_description.json     ← BIDS dataset metadata (pre-configured)
├── license.txt                  ← your FreeSurfer license (you provide this)
├── install_requirements.sh      ← optional — see Quick Start, usually not needed
├── README.md                    ← this file
│
├── scripts/                     ← all pipeline step scripts
│   ├── bootstrap_check.sh       ← runs automatically — checks/fixes your setup
│   ├── 01_dicom_to_bids.sh
│   ├── 02_mriqc.sh
│   ├── 03_freesurfer.sh
│   ├── 04_hcp_preproc.sh
│   ├── 05_qsiprep.sh
│   ├── 06_fmriprep.sh
│   ├── 07_aslprep.sh
│   └── check_important_file_in_bids.py   ← BIDS validator + MRIQC filter generator
│
├── configs/                     ← auto-created at runtime (eddy JSON configs)
├── freesurfer/                  ← auto-installed by install_dependencies.sh (do not move or rename)
├── fsl/                         ← auto-installed by install_dependencies.sh (do not move or rename)
├── HCPpipelines/                ← auto-installed by install_dependencies.sh (do not move or rename)
└── workbench/                   ← auto-installed by install_dependencies.sh (do not move or rename)
```

> The `freesurfer/`, `fsl/`, `HCPpipelines/`, and `workbench/` folders won't exist right after a fresh `git clone` — that's expected. They get created the first time you run `./run_pipeline.sh`. Once installed, they must stay in the same folder as `run_pipeline.sh`; don't move or rename them. Each install is version-pinned and idempotent, so re-running `install_dependencies.sh` (directly or via `run_pipeline.sh`) skips anything already installed at the correct version instead of re-downloading it.

Per-subject outputs are created automatically under `OUTPUT_BASE` (defaults to `PIPELINE_BASE` if you don't set it separately — see [Configure Your Run](#configure-your-run-env)):

```
<OUTPUT_BASE>/
├── sub-<ID>/                    ← BIDS input data (created by Step 01)
│
└── <ID>Processing/              ← all derivatives
    ├── freesurfer/              ← FreeSurfer recon-all output (reused by fMRIPrep + ASLPrep)
    ├── hcp_processing/
    ├── mriqc/
    ├── qsiprep/
    ├── fmriprep/
    ├── aslprep/
    ├── working/                 ← temporary work directories (safe to delete after run)
    └── logs/                    ← timestamped log files for every run attempt
    └── .state/                  ← machine-readable step status (see below — don't edit by hand)
```

---

## Prerequisites

**You don't need to manually check or install any of this yourself.** Every time you start it, `run_pipeline.sh` first checks whether FreeSurfer is installed at `PIPELINE_BASE`; if not, it runs `install_dependencies.sh` automatically, which downloads and installs FreeSurfer, FSL, HCPPipelines, and Workbench for you before anything else happens. It then runs a bootstrap check that looks for everything else below, and if something is missing it prints exactly what to run, or runs it for you. This table exists so you know what's being checked and why, not because you need to act on it before running.

| Requirement | Version | Checked automatically? |
|-------------|---------|------------------------|
| Core tools (FreeSurfer, FSL, HCPpipelines, Workbench) | pinned versions, auto-installed | ✓ Yes — installed automatically into `PIPELINE_BASE` on first run if missing |
| FreeSurfer license (`license.txt`) | — | ✓ Yes — prints registration link if missing |
| Docker | 20.10 or newer | ✓ Yes — detects your OS and prints the install command if missing |
| Python 3 + pip | 3.8 or newer | ✓ Yes — detects your OS and prints the install command if missing |
| dcm2bids, dcm2niix, nibabel, pydicom, tqdm, colorama | latest | ✓ Yes — asks **y/n** before installing anything for you |
| Docker images (MRIQC, FreeSurfer, QSIPrep, fMRIPrep, ASLPrep) | pinned in `.env` | ✓ Yes — pulls automatically in the background, no prompt (this can take a while the first time) |
| DICOM input path / dcm2bids config | — | ✓ Yes — checked per-run since these are subject-specific |

The only thing the pipeline genuinely cannot do for you is hand you a `license.txt` — that has to come from FreeSurfer's registration page (free, instant). The bootstrap check will tell you exactly where to get it and where to put it if it's missing.

### Hardware

| Run mode | Minimum RAM | Recommended |
|----------|-------------|-------------|
| Sequential (default, safest) | 16 GB | 32 GB |
| Parallel Stage 1 — MRIQC + FreeSurfer + HCP together | 60 GB | 80 GB |
| Parallel Stage 2 — QSIPrep + fMRIPrep + ASLPrep together | 100 GB | 128 GB |

**Disk space:** plan for 150–200 GB per subject (raw DICOMs + BIDS + all derivatives).

**GPU (optional):** if an NVIDIA GPU is present, QSIPrep automatically uses CUDA-accelerated eddy correction. Set `EDDY_GPU=OFF` in `.env` to force CPU mode.

---

## Quick Start (Recommended)

First of all download a main-branch zip folder from https://github.com/EN4D2-Computational-Lab/NeuroStage_Pipeline.git or use following in your terminal if you have `git`:

```bash
git clone https://github.com/EN4D2-Computational-Lab/NeuroStage_Pipeline.git
```

This is the entire setup process for a brand-new machine that has nothing installed yet:

```bash
cd neurostage_pipeline
cp .env.template .env
```

Open `.env` in any text editor, for example:

```bash
gedit .env &
```

fill in just the four required fields (`PIPELINE_BASE`, `DICOM_INPUT`, `SUBJECT_ID`, `MATLAB_COMPILER_RUNTIME`) — see [Configure Your Run](#configure-your-run-env) for details. Then run:

```bash
./run_pipeline.sh
```

That's it. Before any data is touched, the script checks your system in this order and tells you exactly what to do for anything missing — or just does it for you:

1. **Core tools (FreeSurfer, FSL, HCPpipelines, Workbench)** — checks whether FreeSurfer is installed at `PIPELINE_BASE`; if not, automatically runs `install_dependencies.sh`, which downloads and installs all four tools at their pinned versions. Nothing to download or clone separately — this happens on its own the very first time you run `./run_pipeline.sh`, and is skipped on every run after that
2. **FreeSurfer license** — confirms `license.txt` exists; if not, gives you the registration link and the exact filename/location to save it as
3. **Docker** — confirms Docker is installed and the daemon is running; if not, detects your OS (Ubuntu/Debian, RHEL/Fedora/AlmaLinux, macOS) and prints the matching install commands
4. **Python 3 / pip** — same idea, OS-specific install commands if missing
5. **Required Python packages** — if any of `dcm2bids`, `dcm2niix`, `nibabel`, `pydicom`, `tqdm`, `colorama` are missing, it **asks you `[y/N]`** before installing them — nothing is installed without your confirmation
6. **Docker images** — pulls any of the required images (MRIQC, FreeSurfer, QSIPrep, fMRIPrep, ASLPrep) that aren't already present. This step does **not** ask for confirmation, since it's not destructive — just a bandwidth/time cost — but it does print progress so you know it's working
7. **DICOM input + dcm2bids config** — confirms your subject's data actually exists at the path you set in `.env`

Once the core tools are installed and every check passes, **the rest is up to you** — see [Running the Pipeline](#running-the-pipeline) below for the full command reference (single full runs, one-step-only runs, dry runs, resuming, `--status`, and so on).

If everything passes, you'll see `✓ All checks passed — starting the pipeline.` and processing begins immediately in the same run — no second invocation needed. If something fails, the script stops cleanly with a numbered list of exactly what to fix, then exits. Nothing is processed until every check passes.

---

## One-Time Setup (Manual)

You normally don't need any of this — `run_pipeline.sh` handles it automatically on first launch. This section exists for people who prefer to set things up by hand, or who are scripting a non-interactive deployment (e.g. CI, a cluster job submission) where prompts aren't possible.

### Step 0 — Install core tools manually (optional)

```bash
./install_dependencies.sh
```

This downloads and installs FreeSurfer, FSL, HCPPipelines, and Workbench at their pinned versions into `PIPELINE_BASE`, exactly what `run_pipeline.sh` would do for you automatically. It's idempotent — safe to re-run, and it skips anything already installed at the correct version — so running it by hand ahead of time just means `run_pipeline.sh` has nothing left to do on that front later.

### Step 1 — Get a FreeSurfer license (free)

Register at https://surfer.nmr.mgh.harvard.edu/registration.html. You will receive a `license.txt` file by email. Copy it into the pipeline folder:

```
neurostage_pipeline/license.txt
```

This is the only external file you must obtain yourself — it can't be bundled or auto-downloaded.

### Step 2 — Install Python dependencies manually

```bash
pip3 install dcm2bids dcm2niix nibabel pydicom tqdm colorama
```

(`install_requirements.sh` does this plus a Docker image pull and disk space check, if you'd rather run one script. It is fully superseded by the automatic bootstrap check inside `run_pipeline.sh`, so using it is optional.)

### Step 3 — Pull Docker images manually

```bash
docker pull nipreps/mriqc:latest
docker pull freesurfer/freesurfer:7.4.1
docker pull pennlinc/qsiprep:latest
docker pull nipreps/fmriprep:latest
docker pull pennlinc/aslprep:latest
```

### Step 4 — GPU users only: build the CUDA-enabled QSIPrep image

Only needed if you have an NVIDIA GPU and want faster eddy correction:

```bash
cd /path/to/neurostage_pipeline
docker build -f qsiprep_fixed.dockerfile -t pennlinc/qsiprep:fixed .
```

If you skip this, the pipeline automatically falls back to CPU eddy — no further action needed.

---

## Configure Your Run (.env)

Copy the template:

```bash
cp .env.template .env
```

Open `.env` in any text editor. **You only need to fill in four fields:**

```bash
# 1. Absolute path to the neurostage_pipeline folder on your machine
PIPELINE_BASE=/path/to/neurostage_pipeline

# 2. Raw DICOM input — folder, nested folder structure, or .zip file
DICOM_INPUT=/path/to/your/subject_dicoms

# 3. Subject label (no "sub-" prefix)
SUBJECT_ID=1004

# 4. Absolute path to your MATLAB version
MATLAB_COMPILER_RUNTIME=/path/to/MATLAB/R2025b/
```

Every other path (FreeSurfer, FSL, HCP, Workbench, license, configs) is derived automatically from `PIPELINE_BASE`.

### Optional: separate input and output disks

```bash
OUTPUT_BASE=/path/to/a/different/disk    # leave unset to use PIPELINE_BASE
```

If unset, all derivatives (BIDS data, FreeSurfer, MRIQC, QSIPrep, fMRIPrep, ASLPrep, logs) are written inside `PIPELINE_BASE`, same as before. Set `OUTPUT_BASE` if you want to keep the auto-installed core tools + BIDS input on one disk and point large per-subject derivatives at a separate disk or array.

### ASL configuration

If you are running ASLPrep (Step 07), set your labeling type:

```bash
ASL_LABELING_TYPE=PCASL    # PCASL (most common), CASL, or PASL
```

If left empty, the pipeline will error at Step 07 rather than prompting interactively, so set this before running.

### Docker image versions

```bash
MRIQC_IMAGE=nipreps/mriqc:latest
QSIPREP_IMAGE=pennlinc/qsiprep:latest
FMRIPREP_IMAGE=nipreps/fmriprep:latest
ASLPREP_IMAGE=pennlinc/aslprep:latest

# FreeSurfer's recon-all output format is tightly coupled to what the HCP
# step (04_hcp_preproc.sh) and downstream surface-map processing expect.
# Only change this if you've explicitly verified compatibility end-to-end.
FREESURFER_IMAGE=freesurfer/freesurfer:7.4.1
```

### Turning steps on or off

```bash
RUN_DCM2BIDS=1      # Step 01 — BIDS conversion
RUN_MRIQC=1         # Step 02 — Quality control
RUN_FREESURFER=1    # Step 03 — FreeSurfer recon-all
RUN_HCP=0           # Step 04 — HCP structural preprocessing
RUN_QSIPREP=1       # Step 05 — Diffusion MRI
RUN_FMRIPREP=1      # Step 06 — Functional MRI
RUN_ASLPREP=1       # Step 07 — Arterial spin labeling
```

Set any step to `0` to skip it.

### Resource limits

```bash
N_THREADS=20        # CPU threads given to each tool
MEM_GB=124          # RAM limit (GB) passed to each Docker tool
OUTPUT_RESOLUTION=1 # QSIPrep output resolution in mm
```

### GPU control

```bash
EDDY_GPU=AUTO       # AUTO=detect, ON=force GPU, OFF=always use CPU
```

### Parallel execution

```bash
PARALLEL_STAGE1=1   # MRIQC + FreeSurfer + HCP run simultaneously
PARALLEL_STAGE2=1   # QSIPrep + fMRIPrep + ASLPrep run simultaneously
```

Leave both as `0` on machines with limited RAM.

---

## Running the Pipeline

**See all available options at any time:**

```bash
./run_pipeline.sh -h
./run_pipeline.sh --help
```

This works even on a brand-new clone with no `.env` and no tools installed yet — the help text is checked for and printed before anything else (before `.env` is loaded, before the core-tools check, before the bootstrap check), so it never fails or hangs waiting on setup. It prints the full flag reference and a few example commands, then exits immediately.

**Full pipeline run** — this is all you normally need. The core-tools check and bootstrap check both run automatically first, every time:

```bash
cd /path/to/neurostage_pipeline
./run_pipeline.sh
```

**Check readiness without running anything:**

```bash
./run_pipeline.sh --preflight
```

This goes further than the automatic bootstrap check — it also validates BIDS data presence, FreeSurfer output state, GPU availability, disk space, and CPU/RAM totals, and prints a full report without executing any step.

**Dry run — print every step that would run, without executing anything:**

```bash
./run_pipeline.sh --dry-run
```

**Show the true current state of every step for this subject:**

```bash
./run_pipeline.sh --status
```

**Override subject or DICOM path on the command line (no need to edit .env):**

```bash
./run_pipeline.sh --subject 1005 --dicom /path/to/1005_dicoms
```

**Override where derivatives are written:**

```bash
./run_pipeline.sh --output /mnt/big_disk/derivatives
```

### Run only one step

```bash
./run_pipeline.sh --only bids
./run_pipeline.sh --only mriqc
./run_pipeline.sh --only freesurfer
./run_pipeline.sh --only hcp
./run_pipeline.sh --only qsiprep
./run_pipeline.sh --only fmriprep
./run_pipeline.sh --only aslprep
```

### Start from a specific step (skip everything before it)

```bash
./run_pipeline.sh --from freesurfer
./run_pipeline.sh --from qsiprep
./run_pipeline.sh --from fmriprep
```

### Force a re-run of a step that's already marked done

```bash
./run_pipeline.sh --only freesurfer --force
```

> **Note:** `--only` and `--from` respect existing completion state. A step already marked `done` is skipped unless you add `--force` (and `--force` only takes effect when combined with `--only`).

---

## Parallel vs Sequential Mode

By default every step runs one at a time. This is the safest mode for most machines. On high-RAM servers, enable parallel stages in `.env`:

```bash
PARALLEL_STAGE1=1   # MRIQC + FreeSurfer + HCP run simultaneously
PARALLEL_STAGE2=1   # QSIPrep + fMRIPrep + ASLPrep run simultaneously
```

Stage 2 always waits for Stage 1 to fully complete before starting — even when parallel mode is on — because fMRIPrep and ASLPrep depend on the FreeSurfer surfaces from Step 03.

Before launching a parallel stage, the pipeline checks available RAM against the expected requirement (60 GB for Stage 1, 100 GB for Stage 2) and warns — but does not block — if there isn't enough.

During a parallel run, a live status table prints every 30 seconds showing each step as `⟳ RUNNING`, `✗ FAILED`, or `✓ OK`, along with elapsed time and the last log line. If one step in a parallel stage fails, the others are left to finish and the pipeline continues into the next stage — re-run the specific failed step afterward with `--only <step> --force`.

> **Warning:** If jobs crash or are killed during parallel execution, reduce `N_THREADS` and `MEM_GB` in `.env` and switch back to sequential (`PARALLEL_STAGE1=0`, `PARALLEL_STAGE2=0`).

---

## How Completion Tracking Works

Each step writes a small state file to `<ID>Processing/.state/<step>.state` every time its status changes. Unlike a simple `.done`/`.failed` flag, this file is updated continuously while the step runs (a heartbeat every 20 seconds) and records the process ID and, if relevant, the Docker container name — which is what lets the pipeline tell the difference between a step that's genuinely still running and one that died silently.

A step's status is always one of:

| Status | Meaning |
|--------|---------|
| `pending` | Never started |
| `running` | Actively running right now (heartbeat is current) |
| `done` | Completed successfully |
| `failed` | Ran and exited with an error |
| `interrupted` | Was running, but the heartbeat went stale and the process is gone — killed, disconnected SSH session, reboot, or OOM kill |
| `orphaned_container` | The driver script died, but its Docker container is still running in the background |

**On every run**, before touching anything, the pipeline prints a "Resume Check" showing the true status of every step for the subject, reconciling any of the crash states above automatically. You never have to guess what happened last time — it's shown to you up front.

- `done` → step is **skipped** automatically.
- `failed` or `interrupted` → step **re-runs** automatically, after stopping any leftover orphaned container first.
- `orphaned_container` → the leftover container is stopped, then the step re-runs.
- `pending` → step runs fresh.

This means a plain `./run_pipeline.sh` after any kind of partial failure, crash, or disconnect is safe and intelligent — completed steps are skipped, broken ones are cleaned up and re-run, everything after runs fresh. You don't need `--from` unless you want to force a specific resume point.

### Forcing a re-run of a completed step

```bash
./run_pipeline.sh --only freesurfer --force
```

No manual file deletion needed — `--force` (combined with `--only`) tells the pipeline to ignore the existing `done` state for that one step.

### FreeSurfer completion is verified with three checks

Step 03 does not rely on a single flag. Before declaring FreeSurfer complete (and before skipping on re-run), it verifies all three of the following:

1. `scripts/recon-all.done` exists inside the FreeSurfer subject folder
2. `scripts/recon-all.log` contains `"finished without error"` — FreeSurfer can write `recon-all.done` even after a partial failure, so the log is the reliable signal
3. Critical output files are present: `mri/aparc+aseg.mgz`, both pial and white surfaces, both cortical parcellation annotation files, and the thickness maps

If any check fails, the existing output folder is archived with a timestamp suffix (`sub-1005_failed_20260615_174532/`) and recon-all restarts from scratch.

### Managing log accumulation

Each run attempt writes a new timestamped log file (e.g. `freesurfer_1005_20260615_174532.log`) into `<ID>Processing/logs/`. Over many re-runs these accumulate. Periodically clean old logs with:

```bash
# Keep only the 3 most recent log files per step
ls -t <ID>Processing/logs/freesurfer_<ID>_*.log | tail -n +4 | xargs rm -f
```

Or archive them before a fresh full run:

```bash
mkdir -p <ID>Processing/logs/archive
mv <ID>Processing/logs/*.log <ID>Processing/logs/archive/
```

The `.state/` folder is small (one short text file per step) and self-maintaining — there's no need to clean it up manually.

---

## Resuming a Failed or Interrupted Run

**Simplest approach — just re-run the same command:**

```bash
./run_pipeline.sh
```

Completed steps are skipped automatically. Failed, interrupted, or orphaned steps are detected, cleaned up, and re-run automatically — including cases where the previous run was killed with Ctrl+C, the SSH session dropped, the machine rebooted, or the OOM killer intervened.

**See exactly what state every step is in before deciding what to do:**

```bash
./run_pipeline.sh --status
```

**Resume from a specific step explicitly:**

```bash
./run_pipeline.sh --from qsiprep
```

**Re-run a single step:**

```bash
./run_pipeline.sh --only fmriprep
```

**QSIPrep / fMRIPrep / ASLPrep crash recovery:** if Docker is killed mid-run, a cleanup trap automatically restores your BIDS `dwi/`, `func/`, and `perf/` folders to their original state. You can safely re-run the same step.

**FreeSurfer crash recovery:** if recon-all crashes or produces incomplete output, the script archives the broken folder and restarts from scratch on the next run. No manual cleanup needed.

**Two people / two terminals running the same subject at once:** the pipeline takes a lock (`<ID>Processing/.state/pipeline.lock`) per subject and refuses to start a second concurrent run for the same `SUBJECT_ID`, so you can't accidentally corrupt state by double-launching.

---

## Output Structure

After a successful run for subject `1005` (assuming `OUTPUT_BASE` was left unset, so it defaults to `PIPELINE_BASE`):

```
neurostage_pipeline/
│
├── sub-1005/                           ← BIDS-formatted input (created by Step 01)
│   ├── anat/
│   ├── dwi/
│   ├── func/
│   └── perf/
│
└── 1005Processing/
    ├── freesurfer/
    │   └── sub-1005/                   ← FreeSurfer surfaces reused by fMRIPrep + ASLPrep
    ├── hcp_processing/
    ├── mriqc/                          ← open index.html here in a browser for QC
    ├── qsiprep/
    ├── fmriprep/
    ├── aslprep/
    ├── working/                        ← intermediate files (safe to delete after run)
    ├── logs/
    │   ├── pipeline_1005_20260615_174532.log     ← master log (all steps combined)
    │   ├── bids_1005_20260615_174532.log         ← per-step timestamped logs
    │   ├── mriqc_1005_20260615_175201.log
    │   ├── freesurfer_1005_20260615_175532.log
    │   ├── qsiprep_1005_20260615_194211.log
    │   ├── fmriprep_1005_20260616_082341.log
    │   └── aslprep_1005_20260616_110532.log
    └── .state/
        ├── pipeline.lock
        ├── bids.state
        ├── mriqc.state
        ├── freesurfer.state
        ├── hcp.state
        ├── qsiprep.state
        ├── fmriprep.state
        └── aslprep.state
```

Each `.state` file is plain text (`step=...`, `status=...`, `pid=...`, `updated=...`) — safe to open and read by hand if you're curious, though `--status` is the supported way to view it.

---

## Troubleshooting

**First time running — what fails and when?**
→ Nothing should "fail" silently anymore. Every run starts with the core-tools check (auto-installing FreeSurfer, FSL, HCPpipelines, and Workbench on the very first run), then the bootstrap check, which walks through license, Docker, Python, pip packages, and Docker images in that order, stopping with a clear numbered explanation at the first thing that's actually missing. If you see a raw bash error instead of a clean `[✗]` message, please report it — that's a gap in the bootstrap check, not expected behavior.

**First run takes a long time before anything else happens / large downloads before Step 01**
→ This is expected. These folders don't ship with the repo — `run_pipeline.sh` detects FreeSurfer is missing and runs `install_dependencies.sh` for you, which downloads FreeSurfer (~7GB), FSL, HCPPipelines, and Workbench into `PIPELINE_BASE`. This only happens once; every run after that skips it because the version markers are already in place.

**`freesurfer/`, `fsl/`, `HCPpipelines/`, or `workbench/` folder still missing after a run, or install seems stuck/failed**
→ Run `./install_dependencies.sh` directly to see the install output in full and get a clearer error (e.g. a network failure mid-download, or a permissions issue writing to `PIPELINE_BASE`). Once fixed, re-run `./run_pipeline.sh` normally.

**Bootstrap check: "license.txt not found"**
→ Register at https://surfer.nmr.mgh.harvard.edu/registration.html (free, instant), save the file you receive as exactly `license.txt` in the same folder as `run_pipeline.sh`.

**Bootstrap check: "Docker is not installed" / prints install commands I don't understand**
→ Copy the exact command block shown — it's already tailored to your OS (Ubuntu/Debian vs RHEL/Fedora/AlmaLinux vs macOS), detected automatically. Paste it into your terminal exactly as shown, then run `./run_pipeline.sh` again.

**Bootstrap check: Python packages — it's asking me y/n, what do I pick?**
→ Type `y` and press Enter to let it install the missing packages for you via pip. Type `n` if you'd rather install them yourself (it will print the exact `pip3 install ...` command either way).

**Pipeline exits silently with no output**
→ FreeSurfer's setup scripts conflict with bash strict mode. The pipeline handles this automatically. If you still see a silent exit, run `bash -x ./run_pipeline.sh 2>&1 | head -100` to trace where it stops, and check that `FREESURFER_HOME` resolves correctly from your `PIPELINE_BASE` in `.env`.

**`--preflight`: "Docker daemon not running"**
→ Start Docker Desktop, or on Linux: `sudo systemctl start docker`. Test with `docker ps`.

**Step 03 (FreeSurfer): archived folder appears (`sub-ID_failed_TIMESTAMP/`)**
→ A previous recon-all run was incomplete. The pipeline archived it and restarted. This is expected behavior. Check `<ID>Processing/freesurfer/sub-<ID>/scripts/recon-all.log` in the archived folder to see what failed.

**Step 03 (FreeSurfer): `recon-all.done` exists but step still re-runs**
→ The three-way completion check failed — most likely `recon-all.log` does not contain `"finished without error"`, or a critical surface file is missing. This means FreeSurfer exited without fully completing. Check the log file inside the archived folder.

**Step 04 (HCP): "PATH NOT FOUND" errors in SetUpHCPPipeline.sh**
→ Open `HCPpipelines/Examples/Scripts/SetUpHCPPipeline.sh` and update any paths to match the auto-installed tool locations inside `PIPELINE_BASE`. The preflight lists every bad path explicitly.

**Step 05 (QSIPrep): "No valid 4D DWI files remain"**
→ The DWI pre-check quarantined all DWI runs. Open the timestamped `qsiprep_<ID>_*.log` and look for `[DWI-CHECK]` lines to see what was flagged. Common causes: missing bval/bvec files, all runs are b0-only.

**Step 05 (QSIPrep): "pennlinc/qsiprep:fixed not found"**
→ A GPU was detected but the fixed image hasn't been built. Either build it:
```bash
docker build -f qsiprep_fixed.dockerfile -t pennlinc/qsiprep:fixed .
```
Or add `EDDY_GPU=OFF` to `.env` to use CPU eddy instead.

**Step 06/07 (fMRIPrep/ASLPrep): "Read-only file system" error on FreeSurfer surfaces**
→ fMRIPrep and ASLPrep need write access to the FreeSurfer output folder to add derived surface files (`midthickness`, `inflated`). The pipeline mounts the FreeSurfer folder as writable — if you see this error it means the volume mount has `:ro` somewhere it shouldn't. Check `06_fmriprep.sh` and `07_aslprep.sh` and ensure the `FS_VOL` line does not include `:ro`.

**Step 06/07 (fMRIPrep/ASLPrep): skips FreeSurfer reuse**
→ FreeSurfer output not found at `<ID>Processing/freesurfer/sub-<ID>/`. Run `./run_pipeline.sh --status` and confirm `freesurfer` shows `✓ DONE`.

**Step 07 (ASLPrep): "No ASL data found" — step skipped**
→ This is expected if the subject has no ASL acquisition. The step exits cleanly with status `0`, not a failure.

**A step shows `done` in `--status` but I want to re-run it anyway**
```bash
./run_pipeline.sh --only fmriprep --force
```

No manual file deletion required.

**A step shows `interrupted` or `orphaned_container` in `--status`**
→ This is expected after a crash, kill, dropped SSH session, or reboot. Just run `./run_pipeline.sh` again — the pipeline detects this automatically, cleans up any leftover Docker container, and re-runs the step.

**"Another pipeline run is already active for this subject"**
→ A previous run for this `SUBJECT_ID` is still active (or its lock file wasn't cleaned up after a hard crash). Run `./run_pipeline.sh --status` to check if anything is genuinely still running (`ps`/`docker ps`). If nothing is actually running, remove `<ID>Processing/.state/pipeline.lock` manually and try again.

**Where are the logs?**
→ `<ID>Processing/logs/`. Each step writes a timestamped log on every run attempt. The master log (`pipeline_<ID>_<datetime>.log`) contains all steps combined. For focused debugging, open the most recent timestamped log for the step that failed.

---
## Step Reference

| `--only` / `--from` name | Script | `.env` flag | Docker image |
|--------------------------|--------|-------------|--------------|
| `bids` | `scripts/01_dicom_to_bids.sh` | `RUN_DCM2BIDS` | — (uses host dcm2bids) |
| `mriqc` | `scripts/02_mriqc.sh` | `RUN_MRIQC` | `MRIQC_IMAGE` |
| `freesurfer` | `scripts/03_freesurfer.sh` | `RUN_FREESURFER` | `FREESURFER_IMAGE` |
| `hcp` | `scripts/04_hcp_preproc.sh` | `RUN_HCP` | — (uses host HCP + FSL) |
| `qsiprep` | `scripts/05_qsiprep.sh` | `RUN_QSIPREP` | `QSIPREP_IMAGE` |
| `fmriprep` | `scripts/06_fmriprep.sh` | `RUN_FMRIPREP` | `FMRIPREP_IMAGE` |
| `aslprep` | `scripts/07_aslprep.sh` | `RUN_ASLPREP` | `ASLPREP_IMAGE` |


---
## Acknowledgments

NeuroStage is an orchestration layer — it does not reimplement any neuroimaging algorithm itself. All actual processing is performed by the open-source tools below, bundled or pulled as Docker images. Full credit for the underlying science and engineering belongs to their respective authors and communities.

### Conversion & data organization

- **[dcm2bids](https://github.com/UNFmontreal/dcm2bids)** — DICOM to BIDS conversion (Bourget, A., et al.)
- **[dcm2niix](https://github.com/rordenlab/dcm2niix)** — DICOM to NIfTI conversion (Li, X., Morgan, P.S., Ashburner, J., Smith, J., Rorden, C., 2016. *The first step for neuroimaging data analysis: DICOM to NIfTI conversion.* J Neurosci Methods, 264:47-56.)
- **[BIDS — Brain Imaging Data Structure](https://bids.neuroimaging.io)** (Gorgolewski, K.J., et al., 2016. *The brain imaging data structure, a format for organizing and describing outputs of neuroimaging experiments.* Sci Data, 3:160044.)

### Quality control

- **[MRIQC](https://mriqc.readthedocs.io)** — automated MRI quality metrics and visual reports (Esteban, O., et al., 2017. *MRIQC: Advancing the automatic prediction of image quality in MRI from unseen sites.* PLoS ONE, 12(9):e0184661.)

### Structural processing

- **[FreeSurfer](https://surfer.nmr.mgh.harvard.edu)** — cortical surface reconstruction and parcellation (Fischl, B., 2012. *FreeSurfer.* NeuroImage, 62(2):774-781.)
- **[HCP Pipelines](https://github.com/Washington-University/HCPpipelines)** — Human Connectome Project structural/functional preprocessing pipelines (Glasser, M.F., et al., 2013. *The minimal preprocessing pipelines for the Human Connectome Project.* NeuroImage, 80:105-124.)
- **[Connectome Workbench](https://www.humanconnectome.org/software/connectome-workbench)** — surface visualization and processing toolkit (Marcus, D.S., et al., 2011. *Informatics and data mining tools and strategies for the Human Connectome Project.* Front Neuroinform, 5:4.)

### Diffusion MRI

- **[QSIPrep](https://qsiprep.readthedocs.io)** — diffusion MRI preprocessing (Cieslak, M., et al., 2021. *QSIPrep: an integrative platform for preprocessing and reconstructing diffusion MRI data.* Nat Methods, 18:775-778.)
- **[FSL eddy](https://fsl.fmrib.ox.ac.uk/fsl/fslwiki/eddy)** — eddy current and motion correction (Andersson, J.L.R., Sotiropoulos, S.N., 2016. *An integrated approach to correction for off-resonance effects and subject movement in diffusion MR imaging.* NeuroImage, 125:1063-1078.)

### Functional MRI

- **[fMRIPrep](https://fmriprep.org)** — functional MRI preprocessing (Esteban, O., et al., 2019. *fMRIPrep: a robust preprocessing pipeline for functional MRI.* Nat Methods, 16:111-116.)

### Perfusion / ASL

- **[ASLPrep](https://aslprep.readthedocs.io)** — arterial spin labeling preprocessing (Adebimpe, A., et al., 2022. *ASLPrep: A platform for processing of arterial spin labeled MRI and quantification of regional brain perfusion.* Nat Methods, 19:683-686.)

### Underlying neuroimaging toolboxes

- **[FSL](https://fsl.fmrib.ox.ac.uk)** — FMRIB Software Library, used internally by HCP Pipelines and QSIPrep (Jenkinson, M., et al., 2012. *FSL.* NeuroImage, 62(2):782-790.)
- **[ANTs / ANTsPy](https://github.com/ANTsX/ANTs)** — image registration and normalization, used internally by fMRIPrep/ASLPrep/QSIPrep (Avants, B.B., et al., 2011. *A reproducible evaluation of ANTs similarity metric performance in brain image registration.* NeuroImage, 54(3):2033-2044.)
- **[Nipype](https://nipype.readthedocs.io)** — workflow engine underlying fMRIPrep, QSIPrep, ASLPrep, and MRIQC (Gorgolewski, K., et al., 2011. *Nipype: a flexible, lightweight and extensible neuroimaging data processing framework in Python.* Front Neuroinform, 5:13.)

### Core Python / scientific computing libraries

- **[NumPy](https://numpy.org)** (Harris, C.R., et al., 2020. *Array programming with NumPy.* Nature, 585:357-362.)
- **[Nibabel](https://nipy.org/nibabel/)** — NIfTI/MGZ file I/O
- **[pydicom](https://pydicom.github.io)** — DICOM file parsing
- **[tqdm](https://github.com/tqdm/tqdm)** — progress bars
- **[colorama](https://github.com/tartley/colorama)** — terminal color output

### Containerization

- **[Docker](https://www.docker.com)** — containerized execution of all preprocessing tools

---

If you use NeuroStage in published research, please cite the individual tools listed above according to each project's own citation guidance, in addition to acknowledging this pipeline.
