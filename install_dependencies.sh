#!/usr/bin/env bash
# =============================================================================
# NeuroStage — Dependency Installer
#
# Installs FreeSurfer, FSL, HCPPipelines, and Connectome Workbench into
# $PIPELINE_BASE, pinned to the exact versions NeuroStage was validated on.
#
# Design goals:
#   - Idempotent: safe to re-run. Skips anything already installed at the
#     correct version.
#   - Self-contained: everything lands under $PIPELINE_BASE, nothing touches
#     system paths, so it plays nicely with .env pointing FREESURFER_HOME /
#     FSLDIR / HCPPIPEDIR / CARET7DIR at these locations.
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
# 1. Pinned versions — the ONLY place version numbers should live
#    (matched to what's actually validated on the UAB HPC build)
# ---------------------------------------------------------------------------
FREESURFER_BUILD="freesurfer-linux-centos7_x86_64-7.4.1-20230613-7eb8460"
FREESURFER_VERSION="7.4.1"
FREESURFER_URL="https://surfer.nmr.mgh.harvard.edu/pub/dist/freesurfer/${FREESURFER_VERSION}/${FREESURFER_BUILD}.tar.gz"

FSL_VERSION="6.0.7.4"
FSL_INSTALLER_URL="https://fsl.fmrib.ox.ac.uk/fsldownloads/fslconda/releases/fslinstaller.py"

# HCPPipelines has no version tags — we track by commit SHA instead so
# re-runs can detect "already cloned" without needing a release number.
HCPPIPELINES_REPO="https://github.com/Washington-University/HCPpipelines.git"

# Workbench: we only keep bin_linux64/ — no GUI, no other-OS binaries, no docs.
WORKBENCH_VERSION="2.0.0"
WORKBENCH_URL="https://github.com/Washington-University/workbench/releases/download/v${WORKBENCH_VERSION}/workbench-linux64-v${WORKBENCH_VERSION}.zip"

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
# 7. Run all
# ---------------------------------------------------------------------------
main() {
    log "Checking NeuroStage dependencies under: $PIPELINE_BASE"
    install_freesurfer
    install_fsl
    install_hcppipelines
    install_workbench
    log "All dependencies present. NeuroStage is ready to run."
}

main "$@"
