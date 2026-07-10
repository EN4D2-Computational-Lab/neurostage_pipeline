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

# ── Free space check (in GB) at a given path's filesystem ────────────────────
_bc_free_gb() {
    local path="$1"
    # Walk up to the nearest existing ancestor so this works even before
    # $PIPELINE_BASE itself has been created yet.
    while [[ ! -d "$path" && "$path" != "/" ]]; do
        path="$(dirname "$path")"
    done
    df -Pk "$path" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}'
}

# =============================================================================
# _bootstrap_check_fast — cheap, fast sanity checks that must pass BEFORE we
# let install_dependencies.sh start pulling down ~15-20GB of tools. Nothing
# in here downloads anything. Call this immediately after .env is sourced,
# BEFORE install_dependencies.sh runs and BEFORE `set -euo pipefail`.
#
# Catching a missing Docker install, a missing python3, an un-edited .env
# placeholder, or a full disk here means a first-time user finds out in
# seconds instead of after a 20-minute download.
# =============================================================================
_bootstrap_check_fast() {
    BC_HARD_FAIL=0

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  NeuroStage — Quick system check (before any downloads start)"
    echo "════════════════════════════════════════════════════════════════"

    # ── A. Basic shell tools we rely on everywhere below ─────────────────────
    _bc_info "Step 1/5 — Checking basic tools (curl, tar, unzip)..."
    local missing_tools=()
    for t in curl tar unzip; do
        command -v "$t" &>/dev/null || missing_tools+=("$t")
    done
    if [[ "${#missing_tools[@]}" -gt 0 ]]; then
        _bc_fail "Missing required command(s): ${missing_tools[*]}"
        local fam; fam=$(_bc_os_family)
        echo ""
        case "$fam" in
            debian) echo "    sudo apt update && sudo apt install -y ${missing_tools[*]}" ;;
            rhel)   echo "    sudo dnf install -y ${missing_tools[*]}" ;;
            macos)  echo "    brew install ${missing_tools[*]}" ;;
            *)      echo "    Install these using your system's package manager." ;;
        esac
        echo ""
    else
        _bc_ok "curl, tar, and unzip found."
    fi

    # ── B. .env sanity — catch un-edited template placeholders early ────────
    _bc_info "Step 2/5 — Checking that .env has been filled in..."
    local placeholder_hit=0
    for var in PIPELINE_BASE DICOM_INPUT DCM2BIDS_CONFIG FS_LICENSE FREESURFER_HOME FSLDIR HCPPIPEDIR; do
        local val="${!var:-}"
        if [[ -z "$val" ]]; then
            _bc_fail "$var is not set in .env"
            placeholder_hit=1
        elif [[ "$val" == *"/path/to/"* || "$val" == *"CHANGE_ME"* || "$val" == *"<"*">"* || "$val" == "TODO"* ]]; then
            _bc_fail "$var still looks like a template placeholder: $val"
            placeholder_hit=1
        fi
    done
    if [[ "$placeholder_hit" -eq 1 ]]; then
        echo ""
        echo "  Open .env in a text editor and replace the flagged value(s) above"
        echo "  with real paths on this machine, then run ./run_pipeline.sh again."
        echo ""
    else
        _bc_ok ".env values look filled in."
    fi

    # ── C. Docker engine + daemon ─────────────────────────────────────────────
    _bc_info "Step 3/5 — Checking Docker..."
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

    # ── D. Python 3 + pip ──────────────────────────────────────────────────────
    _bc_info "Step 4/5 — Checking Python..."
    if ! command -v python3 &>/dev/null; then
        _bc_fail "python3 is not installed."
        _bc_print_python_install
    elif ! command -v pip3 &>/dev/null && ! python3 -m pip --version &>/dev/null; then
        _bc_fail "pip is not installed for python3."
        _bc_print_python_install
    else
        _bc_ok "python3 and pip found."
    fi

    # ── E. Disk space — FreeSurfer + FSL + HCPpipelines + Workbench + MCR
    #        run ~15-20GB combined; Docker images add more on top of that ────
    _bc_info "Step 5/5 — Checking free disk space at PIPELINE_BASE..."
    if [[ -n "${PIPELINE_BASE:-}" ]]; then
        local free_gb; free_gb=$(_bc_free_gb "$PIPELINE_BASE")
        if [[ -n "$free_gb" && "$free_gb" -lt 40 ]]; then
            _bc_fail "Only ${free_gb}GB free near $PIPELINE_BASE. Recommend at least 40GB free before continuing (dependency downloads alone need ~15-20GB, plus room for Docker images and per-subject outputs)."
        else
            _bc_ok "${free_gb:-unknown}GB free — enough to proceed."
        fi
    fi

    if [[ "$BC_HARD_FAIL" -eq 1 ]]; then
        _bc_die
    fi

    echo ""
    echo "  ✓ Quick checks passed. Proceeding to install/verify dependencies..."
    echo ""
}

# =============================================================================
# _bootstrap_check — the heavier checks. Call this once, AFTER
# install_dependencies.sh has run and BEFORE `set -euo pipefail`.
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

    # ── 1. Tool folders present (installed by install_dependencies.sh) ──────
    _bc_info "Step 1/4 — Checking installed tools (FreeSurfer, FSL, HCPpipelines, workbench)..."
    local missing_bundle=0
    for d in "$FREESURFER_HOME" "$FSLDIR" "$HCPPIPEDIR" "${WORKBENCH_DIR:-$PIPELINE_BASE/workbench}"; do
        if [[ ! -d "$d" ]]; then
            _bc_fail "Missing folder: $d"
            missing_bundle=1
        fi
    done
    if [[ "$missing_bundle" -eq 1 ]]; then
        echo ""
        echo "  These folders are supposed to be installed automatically by"
        echo "  install_dependencies.sh (they are NOT bundled in the GitHub"
        echo "  download). This means that script did not complete successfully."
        echo "  Scroll up to check for an earlier error, then try running it"
        echo "  directly to see the full output:"
        echo "    ./install_dependencies.sh"
        echo ""
    else
        _bc_ok "All required tool folders found."
    fi

    # ── 2. FreeSurfer license ────────────────────────────────────────────────
    _bc_info "Step 2/4 — Checking FreeSurfer license..."
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

    if [[ "$BC_HARD_FAIL" -eq 1 ]]; then
        _bc_die
    fi

    # ── 5. Required Python packages (ask before installing) ─────────────────
    _bc_info "Step 3/4 — Checking required Python packages..."
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
    _bc_info "Step 4/4 — Checking required Docker images (will pull any that are missing)..."
    local image_vars=(MRIQC_IMAGE QSIPREP_IMAGE FMRIPREP_IMAGE ASLPREP_IMAGE)
    local images=("${FREESURFER_IMAGE:-freesurfer/freesurfer:7.4.1}")
    for v in "${image_vars[@]}"; do
        if [[ -z "${!v:-}" ]]; then
            _bc_fail "$v is not set in .env — this image is required and cannot be skipped."
        else
            images+=("${!v}")
        fi
    done
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
