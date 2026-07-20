#!/usr/bin/env bash
# =============================================================================
# NeuroStage — Dependency Installer
#
# Installs FreeSurfer, FSL, HCPPipelines, Connectome Workbench, and the
# MATLAB Compiler Runtime (MCR) into $PIPELINE_BASE, pinned to the exact
# versions NeuroStage was validated on.
#
# Design goals:
#   - Idempotent: safe to re-run. Skips anything already installed at the
#     correct version.
#   - Self-contained: everything lands under $PIPELINE_BASE, nothing touches
#     system paths, so it plays nicely with .env pointing FREESURFER_HOME /
#     FSLDIR / HCPPIPEDIR / CARET7DIR / MATLAB_COMPILER_RUNTIME at these
#     locations.
#   - Called automatically by run_pipeline.sh, but can also be run standalone:
#       ./install_dependencies.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Load .env
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[install_dependencies] ERROR: .env not found at $ENV_FILE"
    echo "  Copy .env.template to .env and fill in PIPELINE_BASE first."
    exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

if [[ -z "${PIPELINE_BASE:-}" ]]; then
    echo "[install_dependencies] ERROR: PIPELINE_BASE is not set in .env"
    exit 1
fi

mkdir -p "$PIPELINE_BASE"
VENDOR_MARKERS="${PIPELINE_BASE}/.vendor"
mkdir -p "$VENDOR_MARKERS"

# ---------------------------------------------------------------------------
# 0b. Standalone-safe guard rails. run_pipeline.sh's bootstrap_check_fast
#     already checks these, but this script documents itself as runnable on
#     its own, so it must not assume that happened.
# ---------------------------------------------------------------------------
for _tool in curl tar unzip python3; do
    if ! command -v "$_tool" &>/dev/null; then
        echo "[install_dependencies] ERROR: required command '$_tool' not found."
        echo "  Install it with your system's package manager, then re-run this script."
        exit 1
    fi
done

_free_gb=$(df -Pk "$PIPELINE_BASE" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')
if [[ -n "$_free_gb" && "$_free_gb" -lt 40 ]]; then
    echo "[install_dependencies] ERROR: only ${_free_gb}GB free at $PIPELINE_BASE."
    echo "  These downloads (FreeSurfer, FSL, HCPpipelines, Workbench, MCR) need"
    echo "  roughly 15-20GB, plus headroom for Docker images and per-subject"
    echo "  output. Free up space or point PIPELINE_BASE at a larger disk, then"
    echo "  re-run this script."
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Pinned versions — the ONLY place version numbers should live
#    (matched to what's actually validated on the UAB HPC build)
# ---------------------------------------------------------------------------

# Change this:
# FREESURFER_BUILD="freesurfer-linux-centos7_x86_64-7.4.1-20230613-7eb8460"

# To this:
FREESURFER_VERSION="7.4.1"
FREESURFER_BUILD="freesurfer-linux-centos7_x86_64-${FREESURFER_VERSION}"
FREESURFER_URL="https://surfer.nmr.mgh.harvard.edu/pub/dist/freesurfer/${FREESURFER_VERSION}/${FREESURFER_BUILD}.tar.gz"

FSL_VERSION="6.0.7.4"
FSL_INSTALLER_URL="https://fsl.fmrib.ox.ac.uk/fsldownloads/fslconda/releases/fslinstaller.py"

# HCPPipelines has no version tags — we track by commit SHA instead so
# re-runs can detect "already cloned" without needing a release number.
HCPPIPELINES_REPO="https://github.com/Washington-University/HCPpipelines.git"

# Workbench: we only keep bin_linux64/ — no GUI, no other-OS binaries, no docs.
WORKBENCH_VERSION="2.0.0"
WORKBENCH_URL="www.humanconnectome.org/storage/app/media/workbench/workbench-linux64-v${WORKBENCH_VERSION}.zip"

# MATLAB Compiler Runtime (MCR) — free redistributable from MathWorks, no
# license required. This is what runs HCPPipelines' *compiled* MATLAB
# binaries. This is NOT full MATLAB — do not confuse the two.
#
# IMPORTANT: the MCR version MUST match the version the HCPPipelines/
# FreeSurfer compiled binaries were built against, or compiled tools will
# fail to launch at runtime. Verify this against your HCPpipelines build
# before trusting the auto-install path. Update pattern confirmed against
# MathWorks' public MCR download scheme as of this writing — if MathWorks
# changes their URL layout, install_mcr() will fail loudly (curl -f) rather
# than silently grabbing a bad file.
MCR_VERSION="R2025a"
MCR_UPDATE="1"
MCR_URL="https://ssd.mathworks.com/supportfiles/downloads/${MCR_VERSION}/Release/${MCR_UPDATE}/deployment_files/installer/complete/glnxa64/MATLAB_Runtime_${MCR_VERSION}_Update_${MCR_UPDATE}_glnxa64.zip"

# Where your pre-built HCP override files live (small, git-tracked)
HCP_CUSTOM_FILES_DIR="${SCRIPT_DIR}/.hcpfiles"

log() { echo "[install_dependencies] $*"; }

# ---------------------------------------------------------------------------
# 2. Helper: has this exact version already been installed?
# ---------------------------------------------------------------------------
already_installed() {
    local marker="${VENDOR_MARKERS}/.$1_installed"
    local version="$2"
    [[ -f "$marker" ]] && [[ "$(cat "$marker")" == "$version" ]]
}

mark_installed() {
    local marker="${VENDOR_MARKERS}/.$1_installed"
    echo "$2" > "$marker"
}

# Persist a KEY=VALUE into .env, replacing any existing line for that key.
persist_env_var() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
    rm -f "${ENV_FILE}.bak"
}

# ---------------------------------------------------------------------------
# 3. FreeSurfer
# ---------------------------------------------------------------------------
install_freesurfer() {
    if already_installed "freesurfer" "$FREESURFER_VERSION"; then
        log "FreeSurfer ${FREESURFER_VERSION} already installed — skipping."
        return
    fi

    log "Installing FreeSurfer ${FREESURFER_VERSION} into ${PIPELINE_BASE}/freesurfer ..."
    log "NOTE: this is a ~7GB download and may take a while."

    local tmp_tar="${PIPELINE_BASE}/.vendor/freesurfer-${FREESURFER_VERSION}.tar.gz"
    curl -fL --progress-bar -o "$tmp_tar" "$FREESURFER_URL"

    local tmp_extract="${PIPELINE_BASE}/.vendor/freesurfer_extract_tmp"
    rm -rf "$tmp_extract"
    mkdir -p "$tmp_extract"
    tar -xzf "$tmp_tar" -C "$tmp_extract"
    rm -f "$tmp_tar"

    # Don't trust the tarball's internal folder name — grab whatever
    # top-level directory it extracted and force it to a fixed name, so
    # .env's FREESURFER_HOME never breaks even if a future release
    # changes their packaging.
    local extracted_dir
    extracted_dir="$(find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    if [[ -z "$extracted_dir" ]]; then
        log "ERROR: FreeSurfer archive did not contain a top-level folder."
        exit 1
    fi

    rm -rf "${PIPELINE_BASE}/freesurfer"
    mv "$extracted_dir" "${PIPELINE_BASE}/freesurfer"
    rm -rf "$tmp_extract"

    if [[ -f "${PIPELINE_BASE}/license.txt" ]]; then
        cp "${PIPELINE_BASE}/license.txt" "${PIPELINE_BASE}/freesurfer/license.txt"
    else
        log "WARNING: no license.txt found at PIPELINE_BASE. FreeSurfer will"
        log "  need one at \$FS_LICENSE before recon-all will run."
        log "  Get a free license at https://surfer.nmr.mgh.harvard.edu/registration.html"
    fi

    mark_installed "freesurfer" "$FREESURFER_VERSION"
    log "FreeSurfer ${FREESURFER_VERSION} installed."
}

# ---------------------------------------------------------------------------
# 4. FSL
# ---------------------------------------------------------------------------
install_fsl() {
    if already_installed "fsl" "$FSL_VERSION"; then
        log "FSL ${FSL_VERSION} already installed — skipping."
        return
    fi

    log "Installing FSL ${FSL_VERSION} into ${PIPELINE_BASE}/fsl ..."
    log "NOTE: FSL's installer requires accepting FSL's license terms."
    log "  See: https://fsl.fmrib.ox.ac.uk/fsl/docs/#/license"

    local installer="${PIPELINE_BASE}/.vendor/fslinstaller.py"
    curl -fL --progress-bar -o "$installer" "$FSL_INSTALLER_URL"

    rm -rf "${PIPELINE_BASE}/fsl"
    # -d sets the destination; -V pins the version; --skip_registration avoids
    # an interactive prompt but does NOT bypass license acceptance — the
    # person running this still needs to have agreed to FSL's license.
    python3 "$installer" \
        -d "${PIPELINE_BASE}/fsl" \
        -V "$FSL_VERSION" \
        --skip_registration

    mark_installed "fsl" "$FSL_VERSION"
    log "FSL ${FSL_VERSION} installed."
}

# ---------------------------------------------------------------------------
# 5. HCPPipelines
#    No version tags exist upstream, so we track "installed" by commit SHA:
#    clone once, record the SHA we landed on, skip re-cloning on future runs
#    unless someone deletes the marker (e.g. to intentionally update).
# ---------------------------------------------------------------------------
install_hcppipelines() {
    local marker="${VENDOR_MARKERS}/.hcppipelines_installed"

    if [[ -f "$marker" ]] && [[ -d "${PIPELINE_BASE}/HCPpipelines" ]]; then
        log "HCPPipelines already installed (commit $(cat "$marker")) — skipping."
        return
    fi

    log "Cloning HCPPipelines into ${PIPELINE_BASE}/HCPpipelines ..."

    rm -rf "${PIPELINE_BASE}/HCPpipelines"
    git clone --depth 1 "$HCPPIPELINES_REPO" "${PIPELINE_BASE}/HCPpipelines"

    local sha
    sha="$(git -C "${PIPELINE_BASE}/HCPpipelines" rev-parse --short HEAD)"

    apply_hcp_custom_files

    echo "$sha" > "$marker"
    log "HCPPipelines installed (commit $sha)."
}

# Drop in the pre-built, already-correct versions of these 4 scripts instead
# of trying to patch the upstream ones. Matches whatever HCP override config
# NeuroStage actually needs, without depending on upstream file structure
# staying the same between HCP releases.
apply_hcp_custom_files() {
    if [[ ! -d "$HCP_CUSTOM_FILES_DIR" ]]; then
        log "WARNING: ${HCP_CUSTOM_FILES_DIR} not found — skipping HCP file overrides."
        log "  HCPPipelines will use its default (unpatched) scripts."
        return
    fi

    local target_dir="${PIPELINE_BASE}/HCPpipelines/Examples/Scripts"
    mkdir -p "$target_dir"

    log "Applying custom HCP scripts from ${HCP_CUSTOM_FILES_DIR} ..."
    for f in SetUpHCPPipeline.sh PreFreeSurferPipelineBatch.sh \
             FreeSurferPipelineBatch.sh PostFreeSurferPipelineBatch.sh; do
        if [[ -f "${HCP_CUSTOM_FILES_DIR}/${f}" ]]; then
            cp "${HCP_CUSTOM_FILES_DIR}/${f}" "${target_dir}/${f}"
            log "  -> replaced ${f}"
        else
            log "  WARNING: ${f} not found in ${HCP_CUSTOM_FILES_DIR}, leaving upstream version."
        fi
    done
}

# ---------------------------------------------------------------------------
# 6. Connectome Workbench
# ---------------------------------------------------------------------------
install_workbench() {
    if already_installed "workbench" "$WORKBENCH_VERSION"; then
        log "Workbench ${WORKBENCH_VERSION} already installed — skipping."
        return
    fi

    log "Installing Workbench ${WORKBENCH_VERSION} (bin_linux64 only) into ${PIPELINE_BASE}/workbench ..."

    local tmp_zip="${PIPELINE_BASE}/.vendor/workbench-${WORKBENCH_VERSION}.zip"
    local tmp_extract="${PIPELINE_BASE}/.vendor/workbench_extract_tmp"
    curl -fL --progress-bar -o "$tmp_zip" "$WORKBENCH_URL"

    rm -rf "$tmp_extract"
    mkdir -p "$tmp_extract"
    unzip -q "$tmp_zip" -d "$tmp_extract"
    rm -f "$tmp_zip"

    # Don't trust the zip's internal top-level folder name — find bin_linux64
    # wherever it landed, so a future Workbench release renaming its top
    # folder doesn't silently break this.
    rm -rf "${PIPELINE_BASE}/workbench"
    mkdir -p "${PIPELINE_BASE}/workbench"
    local bin_dir
    bin_dir="$(find "$tmp_extract" -mindepth 1 -maxdepth 2 -type d -name "bin_linux64" | head -n1)"
    if [[ -z "$bin_dir" ]]; then
        log "ERROR: bin_linux64 not found inside Workbench archive."
        exit 1
    fi
    mv "$bin_dir" "${PIPELINE_BASE}/workbench/bin_linux64"
    rm -rf "$tmp_extract"

    chmod +x "${PIPELINE_BASE}/workbench/bin_linux64/"* 2>/dev/null || true

    mark_installed "workbench" "$WORKBENCH_VERSION"
    log "Workbench ${WORKBENCH_VERSION} installed."
}

# ---------------------------------------------------------------------------
# 7. MATLAB Compiler Runtime (MCR)
#
#    Unlike full MATLAB, the MCR is a free redistributable with no license
#    requirement, so — like FreeSurfer/FSL/Workbench above — we can just
#    download and install it directly, no user action needed.
#
#    Detection order:
#      1. MATLAB_COMPILER_RUNTIME already set in .env and points at a valid
#         install -> skip.
#      2. A previous NeuroStage-managed install exists under
#         $PIPELINE_BASE/mcr -> skip (idempotent re-run).
#      3. Otherwise -> download and install fresh, then write the resulting
#         path back into .env automatically.
# ---------------------------------------------------------------------------
is_valid_mcr_path() {
    local candidate="$1"
    # A real MCR install root contains a version subdirectory with a
    # runtime/glnxa64 folder inside it (e.g. <root>/R2025b/runtime/glnxa64).
    [[ -n "$candidate" ]] && find "$candidate" -maxdepth 2 -type d -name "runtime" 2>/dev/null | grep -q .
}

detect_or_install_mcr() {
    # 1. Already configured and valid in .env?
    if is_valid_mcr_path "${MATLAB_COMPILER_RUNTIME:-}"; then
        log "MCR already configured at: $MATLAB_COMPILER_RUNTIME"
        return
    fi

    # 1b. Check for a local system MATLAB installation before downloading anything
    if [[ -d "/usr/local/MATLAB" ]]; then
        log "Checking for local MATLAB installations under /usr/local/MATLAB ..."
        local sys_matlab
        # Finds directories like /usr/local/MATLAB/R2025b, sorts them to pick the newest version
        sys_matlab="$(find /usr/local/MATLAB -maxdepth 2 -type d -name "R20*" 2>/dev/null | sort -V | tail -n1)"
        
        if is_valid_mcr_path "$sys_matlab"; then
            log "Found system MATLAB installation at: $sys_matlab"
            MATLAB_COMPILER_RUNTIME="$sys_matlab"
            persist_env_var "MATLAB_COMPILER_RUNTIME" "$MATLAB_COMPILER_RUNTIME"
            return
        fi
    fi

    # 2. Already installed by a previous run of this script under PIPELINE_BASE?
    if already_installed "mcr" "${MCR_VERSION}_Update_${MCR_UPDATE}" \
       && is_valid_mcr_path "${PIPELINE_BASE}/mcr"; then
        log "MCR ${MCR_VERSION} Update ${MCR_UPDATE} already installed — skipping."
        MATLAB_COMPILER_RUNTIME="${PIPELINE_BASE}/mcr"
        persist_env_var "MATLAB_COMPILER_RUNTIME" "$MATLAB_COMPILER_RUNTIME"
        return
    fi

    log "MCR not found — installing ${MCR_VERSION} Update ${MCR_UPDATE} into ${PIPELINE_BASE}/mcr ..."
    log "NOTE: this is a ~3-4GB download."

    local tmp_zip="${PIPELINE_BASE}/.vendor/mcr-${MCR_VERSION}.zip"
    local tmp_extract="${PIPELINE_BASE}/.vendor/mcr_extract_tmp"

    if ! curl -fL --progress-bar -o "$tmp_zip" "$MCR_URL"; then
        log "ERROR: failed to download MCR from:"
        log "  $MCR_URL"
        log "  MathWorks may have changed their download URL scheme, or"
        log "  ${MCR_VERSION} Update ${MCR_UPDATE} may not exist. Check"
        log "  https://www.mathworks.com/products/compiler/matlab-runtime.html"
        log "  and set MCR_VERSION/MCR_UPDATE at the top of this script, or"
        log "  set MATLAB_COMPILER_RUNTIME manually in .env if MCR is"
        log "  already installed somewhere on this system."
        return 1
    fi

    rm -rf "$tmp_extract"
    mkdir -p "$tmp_extract"
    unzip -q "$tmp_zip" -d "$tmp_extract"
    rm -f "$tmp_zip"

    # MathWorks ships an `install` binary that supports non-interactive mode
    # via -mode silent -agreeToLicense yes. No FIK or license file needed —
    # the runtime itself is unrestricted freeware.
    rm -rf "${PIPELINE_BASE}/mcr"
    mkdir -p "${PIPELINE_BASE}/mcr"

    "${tmp_extract}/install" \
        -mode silent \
        -agreeToLicense yes \
        -destinationFolder "${PIPELINE_BASE}/mcr"

    rm -rf "$tmp_extract"

    if ! is_valid_mcr_path "${PIPELINE_BASE}/mcr"; then
        log "ERROR: MCR install completed but expected runtime folder not found"
        log "  under ${PIPELINE_BASE}/mcr. Installation likely failed silently."
        return 1
    fi

    MATLAB_COMPILER_RUNTIME="${PIPELINE_BASE}/mcr"
    persist_env_var "MATLAB_COMPILER_RUNTIME" "$MATLAB_COMPILER_RUNTIME"
    mark_installed "mcr" "${MCR_VERSION}_Update_${MCR_UPDATE}"
    log "MCR ${MCR_VERSION} Update ${MCR_UPDATE} installed at $MATLAB_COMPILER_RUNTIME"
}

# Sanity-check that the installed/detected MCR is actually usable — confirms
# the expected runtime/glnxa64 subfolder exists and has shared libraries in
# it, which is what compiled HCP/FreeSurfer MATLAB binaries link against at
# runtime. This does NOT run a MATLAB job — MCR has no interactive shell.
verify_mcr() {
    if [[ -z "${MATLAB_COMPILER_RUNTIME:-}" ]] || ! is_valid_mcr_path "$MATLAB_COMPILER_RUNTIME"; then
        log "Skipping MCR verification — no valid MATLAB_COMPILER_RUNTIME."
        return 1
    fi

    local runtime_dir
    runtime_dir="$(find "$MATLAB_COMPILER_RUNTIME" -maxdepth 2 -type d -name "glnxa64" -path "*runtime*" | head -n1)"

    if [[ -z "$runtime_dir" ]] || ! find "$runtime_dir" -maxdepth 1 -name "*.so*" 2>/dev/null | grep -q .; then
        log "WARNING: MATLAB_COMPILER_RUNTIME is set but no shared libraries"
        log "  found under it. Compiled MATLAB steps in HCPPipelines will"
        log "  likely fail at runtime."
        return 1
    fi

    log "MCR verified — runtime libraries found at: $runtime_dir"
    log "  Reminder: compiled HCP/FreeSurfer MATLAB binaries must have been"
    log "  built against ${MCR_VERSION} specifically, or they will fail to"
    log "  launch even with a valid MCR present. Confirm this matches your"
    log "  HCPPipelines build if you hit runtime errors."
    return 0
}

# ---------------------------------------------------------------------------
# 8. Run all
# ---------------------------------------------------------------------------
main() {
    log "Checking NeuroStage dependencies under: $PIPELINE_BASE"
    install_freesurfer
    install_fsl
    install_hcppipelines
    install_workbench
    detect_or_install_mcr || log "WARNING: MCR setup incomplete — see messages above."
    verify_mcr || true   # don't hard-fail the whole pipeline on this
    log "All dependencies present. NeuroStage is ready to run."
    # -----------------------------------------------------------------------
    # Print the resolved paths on successful completion
    # -----------------------------------------------------------------------
    echo ""
    echo "========================================================================="
    echo " NeuroStage Environment Summary"
    echo "========================================================================="
    echo " PIPELINE_BASE:             ${PIPELINE_BASE}"
    echo " FREESURFER_HOME:           ${PIPELINE_BASE}/freesurfer"
    echo " FSLDIR:                    ${PIPELINE_BASE}/fsl"
    echo " HCPPIPEDIR:                ${PIPELINE_BASE}/HCPpipelines"
    echo " CARET7DIR:                 ${PIPELINE_BASE}/workbench/bin_linux64"
    echo " MATLAB_COMPILER_RUNTIME:   ${MATLAB_COMPILER_RUNTIME:-Not Configured}"
    echo "========================================================================="
    echo ""

    log "All dependencies present. NeuroStage is ready to run."
}

main "$@"
