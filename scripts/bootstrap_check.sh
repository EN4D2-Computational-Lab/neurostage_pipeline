#!/usr/bin/env bash
# =============================================================================
# bootstrap_check.sh — First-line dependency gatekeeper for NeuroStage
#
# Sourced by run_pipeline.sh BEFORE `set -euo pipefail` is enabled, so every
# check in here must handle its own failures (no relying on the caller's
# strict mode) and must never let a single failed `command -v` or grep kill
# the whole shell via an inherited `set -e`.
#
# Goal: a person with zero terminal experience runs `./run_pipeline.sh`,
# and if anything required is missing, they get a short, copy-pasteable,
# numbered list of exactly what to do — not a stack of bash errors.
#
# This file defines _bootstrap_check(); it does not call it. run_pipeline.sh
# calls it explicitly right after .env is loaded.
# =============================================================================

# Re-declare lightweight printers here so this file works even if sourced
# before run_pipeline.sh's own _info/_warn/_error are defined.
_bc_ok()    { echo "  [✓]  $*"; }
_bc_fail()  { echo "  [✗]  $*"; BC_HARD_FAIL=1; }
_bc_warn()  { echo "  [!]  $*"; }
_bc_info()  { echo "  [i]  $*"; }
_bc_die() {
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  SETUP INCOMPLETE — fix the item(s) marked [✗] above, then"
    echo "  run ./run_pipeline.sh again. Nothing has been processed yet."
    echo "════════════════════════════════════════════════════════════════"
    exit 1
}

# ── OS detection — used to print the right install command ───────────────────
_bc_os_family() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        case "${ID:-}${ID_LIKE:-}" in
            *debian*|*ubuntu*) echo "debian" ;;
            *rhel*|*fedora*|*centos*|*almalinux*|*rocky*) echo "rhel" ;;
            *) echo "unknown" ;;
        esac
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        echo "macos"
    else
        echo "unknown"
    fi
}

_bc_print_docker_install() {
    local fam; fam=$(_bc_os_family)
    echo ""
    echo "  Docker is not installed. Install it with:"
    case "$fam" in
        debian)
            cat <<'EOF'
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
    # Then log out and back in (or run: newgrp docker)
EOF
            ;;
        rhel)
            cat <<'EOF'
    sudo dnf -y install dnf-plugins-core
    sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER
    # Then log out and back in (or run: newgrp docker)
EOF
            ;;
        macos)
            cat <<'EOF'
    Download and install Docker Desktop from:
    https://www.docker.com/products/docker-desktop
EOF
            ;;
        *)
            cat <<'EOF'
    Visit https://docs.docker.com/engine/install/ and follow the
    instructions for your operating system.
EOF
            ;;
    esac
    echo ""
}

_bc_print_python_install() {
    local fam; fam=$(_bc_os_family)
    echo ""
    echo "  Python 3 / pip is not installed. Install it with:"
    case "$fam" in
        debian)
            echo "    sudo apt update && sudo apt install -y python3 python3-pip"
            ;;
        rhel)
            echo "    sudo dnf install -y python3 python3-pip"
            ;;
        macos)
            echo "    brew install python3   (or https://www.python.org/downloads/)"
            ;;
        *)
            echo "    Visit https://www.python.org/downloads/"
            ;;
    esac
    echo ""
}

# ── y/n prompt — defaults to No on empty/garbage input ────────────────────────
_bc_confirm() {
    local prompt="$1" reply
    read -r -p "  $prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# =============================================================================
# _bootstrap_check — the main entry point. Call this once, right after .env
# is sourced and BEFORE `set -euo pipefail`.
#
# Expects these to already be set (from .env): PIPELINE_BASE, FS_LICENSE,
# FREESURFER_HOME, FSLDIR, HCPPIPEDIR, MRIQC_IMAGE, QSIPREP_IMAGE,
# FMRIPREP_IMAGE, ASLPREP_IMAGE, FREESURFER_IMAGE, DICOM_INPUT,
# DCM2BIDS_CONFIG.
# =============================================================================
_bootstrap_check() {
    BC_HARD_FAIL=0

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  NeuroStage — Checking your system before we start"
    echo "════════════════════════════════════════════════════════════════"

    # ── 1. Bundled tools present (these ship in the download/clone) ─────────
    _bc_info "Step 1/6 — Checking bundled tools (FreeSurfer, FSL, HCPpipelines, workbench)..."
    local missing_bundle=0
    for d in "$FREESURFER_HOME" "$FSLDIR" "$HCPPIPEDIR" "${WORKBENCH_DIR:-$PIPELINE_BASE/workbench}"; do
        if [[ ! -d "$d" ]]; then
            _bc_fail "Missing folder: $d"
            missing_bundle=1
        fi
    done
    if [[ "$missing_bundle" -eq 1 ]]; then
        echo ""
        echo "  These folders should have come bundled in your download/clone of"
        echo "  the neurostage_pipeline folder. If they're missing, your download"
        echo "  is incomplete — re-download or re-clone the full repository rather"
        echo "  than just the scripts."
        echo ""
    else
        _bc_ok "All bundled tool folders found."
    fi

    # ── 2. FreeSurfer license ────────────────────────────────────────────────
    _bc_info "Step 2/6 — Checking FreeSurfer license..."
    if [[ ! -f "$FS_LICENSE" ]]; then
        _bc_fail "license.txt not found at: $FS_LICENSE"
        echo ""
        echo "  This file is free but must be requested individually — it can't"
        echo "  be bundled in the download. To get it:"
        echo "    1. Go to: https://surfer.nmr.mgh.harvard.edu/registration.html"
        echo "    2. Fill out the short form (instant, free, no approval wait)"
        echo "    3. You'll receive a license.txt file by email"
        echo "    4. Save that file as exactly: $FS_LICENSE"
        echo ""
    else
        _bc_ok "FreeSurfer license found."
    fi

    # ── 3. Docker engine + daemon ────────────────────────────────────────────
    _bc_info "Step 3/6 — Checking Docker..."
    if ! command -v docker &>/dev/null; then
        _bc_fail "Docker is not installed."
        _bc_print_docker_install
    elif ! docker info &>/dev/null; then
        _bc_fail "Docker is installed but the Docker daemon isn't running / you don't have permission to use it."
        echo ""
        echo "  Try:"
        echo "    sudo systemctl start docker     # Linux"
        echo "    (or open Docker Desktop, if on macOS/Windows)"
        echo ""
        echo "  If you just installed Docker and added yourself to the docker group,"
        echo "  you likely need to log out and back in for that to take effect."
        echo ""
    else
        _bc_ok "Docker is installed and running."
    fi

    # ── 4. Python 3 + pip ────────────────────────────────────────────────────
    _bc_info "Step 4/6 — Checking Python..."
    if ! command -v python3 &>/dev/null; then
        _bc_fail "python3 is not installed."
        _bc_print_python_install
    elif ! command -v pip3 &>/dev/null && ! python3 -m pip --version &>/dev/null; then
        _bc_fail "pip is not installed for python3."
        _bc_print_python_install
    else
        _bc_ok "python3 and pip found."
    fi

    # If anything in steps 1-4 failed, there's no point asking about pip
    # packages or pulling docker images yet — stop here with a clean list.
    if [[ "$BC_HARD_FAIL" -eq 1 ]]; then
        _bc_die
    fi

    # ── 5. Required Python packages (ask before installing) ─────────────────
    _bc_info "Step 5/6 — Checking required Python packages..."
    local need_pkgs=()
    for mod_pkg in "dcm2bids:dcm2bids" "nibabel:nibabel" "pydicom:pydicom" "tqdm:tqdm" "colorama:colorama"; do
        local mod="${mod_pkg%%:*}" pkg="${mod_pkg##*:}"
        python3 -c "import ${mod}" &>/dev/null || need_pkgs+=("$pkg")
    done
    # dcm2niix is a binary dcm2bids depends on, not a pip-importable module —
    # check it separately via command -v.
    command -v dcm2niix &>/dev/null || need_pkgs+=("dcm2niix")

    if [[ "${#need_pkgs[@]}" -eq 0 ]]; then
        _bc_ok "All required Python packages found."
    else
        _bc_warn "Missing Python packages: ${need_pkgs[*]}"
        if _bc_confirm "Install them now with pip?"; then
            _bc_info "Installing: ${need_pkgs[*]} ..."
            if pip3 install --quiet "${need_pkgs[@]}"; then
                _bc_ok "Installed successfully."
            else
                _bc_fail "pip install failed. Try manually: pip3 install ${need_pkgs[*]}"
                _bc_die
            fi
        else
            echo ""
            echo "  To install manually, run:"
            echo "    pip3 install ${need_pkgs[*]}"
            echo ""
            _bc_die
        fi
    fi

    # ── 6. Docker images (auto-pull silently, no prompt — bandwidth/time"
    #        cost only, not a destructive or ambiguous action) ───────────────
    _bc_info "Step 6/6 — Checking required Docker images (will pull any that are missing)..."
    local images=(
        "${FREESURFER_IMAGE:-freesurfer/freesurfer:7.4.1}"
        "${MRIQC_IMAGE}"
        "${QSIPREP_IMAGE}"
        "${FMRIPREP_IMAGE}"
        "${ASLPREP_IMAGE}"
    )
    for img in "${images[@]}"; do
        [[ -z "$img" ]] && continue
        if docker image inspect "$img" &>/dev/null; then
            _bc_ok "Image already present: $img"
        else
            _bc_info "Pulling $img — this can take a while the first time..."
            if docker pull "$img"; then
                _bc_ok "Pulled: $img"
            else
                _bc_fail "Failed to pull: $img (check internet connection / Docker Hub access)"
            fi
        fi
    done

    if [[ "$BC_HARD_FAIL" -eq 1 ]]; then
        _bc_die
    fi

    # ── 7. Input data sanity (kept separate from the numbered 1-6 above
    #        since DICOM/config paths are per-subject, not one-time setup) ───
    if [[ ! -e "${DICOM_INPUT:-}" ]]; then
        _bc_fail "DICOM_INPUT not found: ${DICOM_INPUT:-<not set>}"
        echo "  Edit .env and set DICOM_INPUT to the folder or .zip containing this subject's DICOMs."
    fi
    if [[ ! -f "${DCM2BIDS_CONFIG:-}" ]]; then
        _bc_fail "dcm2bids config not found: ${DCM2BIDS_CONFIG:-<not set>}"
    fi
    if [[ "$BC_HARD_FAIL" -eq 1 ]]; then
        _bc_die
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  ✓ All checks passed — starting the pipeline."
    echo "════════════════════════════════════════════════════════════════"
    echo ""
}
