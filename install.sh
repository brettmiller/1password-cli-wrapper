#!/usr/bin/env bash
# install.sh - installs, updates, or uninstalls opa
#
# Usage: install.sh [--help | --update | --uninstall]
#
# Environment variables (override interactive prompts):
#   OP_REAL       - path to the real op binary     (default: auto-detected)
#   INSTALL_DIR   - where to install opa           (default: /usr/local/bin)
#   WIRE_AS_OP    - how to expose as 'op': symlink, alias, or none
#   OP_LINK_DIR   - where to create the op symlink (default: prompted; symlink only)
#   RC_FILE       - rc file to add the op alias to  (default: prompted; alias only)

set -euo pipefail

die()  { echo "install: error: $*" >&2; exit 1; }
info() { echo "  $*"; }
ask()  {
    local var="${1}" prompt="${2}" default="${3}"
    local val
    read -r -p "  ${prompt} [${default}]: " val
    printf -v "${var}" '%s' "${val:-${default}}"
}

# Escape a string for use as a literal in a | -delimited sed pattern.
sed_escape_pattern()     { printf '%s' "${1}" | sed 's/[].[\*^$|]/\\&/g'; }
# Escape a string for use in a | -delimited sed replacement.
sed_escape_replacement() { printf '%s' "${1}" | sed 's/[\\&|]/\\&/g'; }

# True if <dir> is present in PATH.
on_path() { [[ ":${PATH}:" == *":${1}:"* ]]; }

# ── mode ─────────────────────────────────────────────────────────────────────

MODE="install"
case "${1:-}" in
    --help|-h)   MODE="help" ;;
    --update)    MODE="update" ;;
    --uninstall) MODE="uninstall" ;;
    "")          ;;
    *)           die "Unknown option: '${1}'. Use --help for usage." ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPA_SRC="${SCRIPT_DIR}/opa"

[[ -f "${OPA_SRC}" ]] || die "opa script not found at ${OPA_SRC}"

# ── detection helpers ─────────────────────────────────────────────────────────

detect_op() {
    for candidate in \
        "$(command -v op 2>/dev/null || true)" \
        /opt/homebrew/bin/op \
        /usr/local/bin/op; do
        [[ -x "${candidate}" ]] && { printf '%s' "${candidate}"; return; }
    done
    printf ''
}

detect_opa() {
    for candidate in \
        "$(command -v opa 2>/dev/null || true)" \
        /usr/local/bin/opa \
        "${HOME}/.local/bin/opa" \
        "${HOME}/bin/opa"; do
        [[ -x "${candidate}" ]] && { printf '%s' "${candidate}"; return; }
    done
    printf ''
}

DETECTED_OP="$(detect_op)"
EXISTING_OPA="$(detect_opa)"

# ── help ──────────────────────────────────────────────────────────────────────

if [[ "${MODE}" == "help" ]]; then
    cat <<'EOF'

opa installer

Usage:
  install.sh             Interactive install; offers update if opa is already installed
  install.sh --update    Update an existing opa installation
  install.sh --uninstall Remove opa and any op symlink that points to it
  install.sh --help      Show this help

Environment variables (skip interactive prompts):
  OP_REAL       Path to the real op binary     (default: auto-detected)
  INSTALL_DIR   Where to install opa           (default: /usr/local/bin)
  WIRE_AS_OP    How to expose as 'op'          (symlink | alias | none)
  OP_LINK_DIR   Where to create the op symlink (symlink mode only)
  RC_FILE       RC file to add the alias to    (alias mode only)

EOF
    exit 0
fi

# ── update ────────────────────────────────────────────────────────────────────

run_update() {
    echo ""
    echo "opa update"
    echo "─────────────────────────────────────────"
    echo ""

    if [[ -z "${EXISTING_OPA}" ]]; then
        ask EXISTING_OPA "Path to installed opa" "/usr/local/bin/opa"
    else
        info "Found: ${EXISTING_OPA}"
        echo ""
    fi
    [[ -x "${EXISTING_OPA}" ]] || die "opa not found or not executable at '${EXISTING_OPA}'"

    echo "Real op binary"
    if [[ -n "${DETECTED_OP}" ]]; then
        local _ver
        _ver="$(${DETECTED_OP} --version 2>/dev/null || echo 'version unknown')"
        info "Detected: ${DETECTED_OP}  (${_ver})"
    fi
    local _current_real
    _current_real="$(grep '^OP_REAL_DEFAULT=' "${EXISTING_OPA}" | cut -d'"' -f2)"
    [[ -n "${_current_real}" ]] && info "Currently set: ${_current_real}"

    OP_REAL="${OP_REAL:-}"
    if [[ -z "${OP_REAL}" ]]; then
        ask OP_REAL "Path to real op binary" "${DETECTED_OP:-${_current_real:-/usr/local/bin/op}}"
    fi
    [[ -x "${OP_REAL}" ]] || die "op binary not found or not executable: '${OP_REAL}'"

    local _escaped_real
    _escaped_real="$(sed_escape_replacement "${OP_REAL}")"
    sed "s|^OP_REAL_DEFAULT=\"[^\"]*\"|OP_REAL_DEFAULT=\"${_escaped_real}\"|" \
        "${OPA_SRC}" > "${EXISTING_OPA}"
    chmod +x "${EXISTING_OPA}"

    echo ""
    echo "─────────────────────────────────────────"
    echo "Done."
    echo ""
    echo "opa updated : ${EXISTING_OPA}"
    echo "op binary   : ${OP_REAL}"
    echo ""
}

# ── uninstall ─────────────────────────────────────────────────────────────────

run_uninstall() {
    echo ""
    echo "opa uninstall"
    echo "─────────────────────────────────────────"
    echo ""

    if [[ -z "${EXISTING_OPA}" ]]; then
        ask EXISTING_OPA "Path to installed opa" "/usr/local/bin/opa"
    else
        info "Found: ${EXISTING_OPA}"
    fi
    [[ -f "${EXISTING_OPA}" ]] || die "opa not found at '${EXISTING_OPA}'"

    # Remove any op symlinks that point at this opa
    local _opa_dir _links_removed _candidate
    _opa_dir="$(dirname "${EXISTING_OPA}")"
    _links_removed=0
    for _candidate in \
        "${_opa_dir}/op" \
        "${HOME}/.local/bin/op" \
        "${HOME}/bin/op"; do
        local _target
        _target="$(readlink "${_candidate}" 2>/dev/null || true)"
        if [[ -L "${_candidate}" && "${_target}" == "${EXISTING_OPA}" ]]; then
            rm "${_candidate}"
            info "Removed symlink: ${_candidate}"
            _links_removed=$(( _links_removed + 1 ))
        fi
    done

    rm "${EXISTING_OPA}"
    info "Removed: ${EXISTING_OPA}"

    echo ""
    echo "─────────────────────────────────────────"
    echo "Done."
    if [[ "${_links_removed}" -eq 0 ]]; then
        echo ""
        info "Note: if you added 'alias op=opa' to a shell RC file, remove it manually."
    fi
    echo ""
}

# ── dispatch non-install modes ────────────────────────────────────────────────

if [[ "${MODE}" == "update" ]]; then
    run_update
    exit 0
fi

if [[ "${MODE}" == "uninstall" ]]; then
    run_uninstall
    exit 0
fi

# ── install ───────────────────────────────────────────────────────────────────

echo ""
echo "opa installer"
echo "─────────────────────────────────────────"

# Offer to update if opa is already installed
if [[ -n "${EXISTING_OPA}" ]]; then
    echo ""
    info "opa is already installed at: ${EXISTING_OPA}"
    _CHOICE=""
    ask _CHOICE "Update the existing install, or do a full reinstall? (update/reinstall)" "update"
    if [[ "${_CHOICE}" == "update" ]]; then
        run_update
        exit 0
    fi
fi

# ── detect real op ────────────────────────────────────────────────────────────

echo ""
echo "Real op binary"
if [[ -n "${DETECTED_OP}" ]]; then
    _detected_ver="$(${DETECTED_OP} --version 2>/dev/null || echo 'version unknown')"
    info "Detected: ${DETECTED_OP}  (${_detected_ver})"
fi

OP_REAL="${OP_REAL:-}"
if [[ -z "${OP_REAL}" ]]; then
    ask OP_REAL "Path to real op binary" "${DETECTED_OP:-/usr/local/bin/op}"
fi
[[ -x "${OP_REAL}" ]] || die "op binary not found or not executable: '${OP_REAL}'"
info "Using: ${OP_REAL}"

# ── install directory ─────────────────────────────────────────────────────────

echo ""
echo "Install location"
INSTALL_DIR="${INSTALL_DIR:-}"
if [[ -z "${INSTALL_DIR}" ]]; then
    ask INSTALL_DIR "Install opa to" "/usr/local/bin"
fi
[[ -d "${INSTALL_DIR}" ]] || { info "Creating ${INSTALL_DIR}"; mkdir -p "${INSTALL_DIR}"; }

# ── write opa with the detected op path baked in ──────────────────────────────

OPA_DEST="${INSTALL_DIR}/opa"
_escaped_real="$(sed_escape_replacement "${OP_REAL}")"
sed "s|^OP_REAL_DEFAULT=\"\"|OP_REAL_DEFAULT=\"${_escaped_real}\"|" \
    "${OPA_SRC}" > "${OPA_DEST}"
chmod +x "${OPA_DEST}"
info "Installed: ${OPA_DEST}"

# shellcheck disable=SC2310
if ! on_path "${INSTALL_DIR}"; then
    info "Note: ${INSTALL_DIR} is not on your PATH — add it so 'opa' can be found by name."
fi

# ── optionally wire as 'op' ───────────────────────────────────────────────────

echo ""
echo "Wire as 'op'?"
info "symlink  - create an op -> opa symlink in a directory of your choice"
info "alias    - add 'alias op=opa' to your shell rc file"
info "none     - use 'opa' directly, set up 'op' yourself later"
echo ""

WIRE_AS_OP="${WIRE_AS_OP:-}"
if [[ -z "${WIRE_AS_OP}" ]]; then
    ask WIRE_AS_OP "Choice (symlink/alias/none)" "none"
fi

case "${WIRE_AS_OP}" in
    symlink)
        echo ""
        echo "Where should the 'op' symlink be created?"
        info "1) ~/bin         (${HOME}/bin)"
        info "2) ~/.local/bin  (${HOME}/.local/bin)"
        info "   or enter a custom path"
        echo ""

        OP_LINK_DIR="${OP_LINK_DIR:-}"
        if [[ -z "${OP_LINK_DIR}" ]]; then
            ask OP_LINK_DIR "Destination (1/2/path)" "2"
        fi
        case "${OP_LINK_DIR}" in
            1) OP_LINK_DIR="${HOME}/bin" ;;
            2) OP_LINK_DIR="${HOME}/.local/bin" ;;
            *) ;;  # treat as a literal path
        esac
        [[ -d "${OP_LINK_DIR}" ]] || { info "Creating ${OP_LINK_DIR}"; mkdir -p "${OP_LINK_DIR}"; }

        # shellcheck disable=SC2310
        if ! on_path "${OP_LINK_DIR}"; then
            info "Note: ${OP_LINK_DIR} is not on your PATH — 'op' won't be found until it is."
        fi

        OP_LINK="${OP_LINK_DIR}/op"
        # If op already exists at that path, back it up
        if [[ -e "${OP_LINK}" && ! -L "${OP_LINK}" ]]; then
            info "Backing up existing ${OP_LINK} to ${OP_LINK}.real"
            mv "${OP_LINK}" "${OP_LINK}.real"
            # Update OP_REAL to point to the backup if it was at that path
            if [[ "${OP_REAL}" == "${OP_LINK}" ]]; then
                info "Updating OP_REAL_DEFAULT in opa to ${OP_LINK}.real"
                _pat="$(sed_escape_pattern "${OP_REAL}")"
                _rep="$(sed_escape_replacement "${OP_LINK}.real")"
                _tmp="$(mktemp)"
                sed "s|OP_REAL_DEFAULT=\"${_pat}\"|OP_REAL_DEFAULT=\"${_rep}\"|" \
                    "${OPA_DEST}" > "${_tmp}" && mv "${_tmp}" "${OPA_DEST}"
                chmod +x "${OPA_DEST}"
            fi
        elif [[ -L "${OP_LINK}" ]]; then
            rm "${OP_LINK}"
        fi
        ln -s "${OPA_DEST}" "${OP_LINK}"
        info "Symlink created: ${OP_LINK} -> ${OPA_DEST}"
        ;;
    alias)
        # shellcheck disable=SC2310
        if ! on_path "${INSTALL_DIR}"; then
            info "Warning: ${INSTALL_DIR} is not on PATH — the alias 'op=opa' won't work until it is."
        fi
        # Detect shell rc file
        local_shell="$(basename "${SHELL:-bash}")"
        case "${local_shell}" in
            zsh)  RC_DEFAULT="${HOME}/.zshrc" ;;
            bash) RC_DEFAULT="${HOME}/.bashrc" ;;
            *)    RC_DEFAULT="${HOME}/.profile" ;;
        esac

        echo ""
        echo "Which file should the alias be added to?"
        info "1) Detected default  (${RC_DEFAULT})"
        info "   or enter a custom path"
        echo ""

        RC_FILE="${RC_FILE:-}"
        if [[ -z "${RC_FILE}" ]]; then
            ask RC_FILE "RC file (1/path)" "1"
        fi
        case "${RC_FILE}" in
            1) RC_FILE="${RC_DEFAULT}" ;;
            *) ;;  # treat as a literal path
        esac
        [[ -d "$(dirname "${RC_FILE}")" ]] \
            || die "parent directory of '${RC_FILE}' does not exist"
        [[ ! -e "${RC_FILE}" || -w "${RC_FILE}" ]] \
            || die "'${RC_FILE}' exists but is not writable"
        ALIAS_LINE="alias op='opa'"
        if grep -qF "${ALIAS_LINE}" "${RC_FILE}" 2>/dev/null; then
            info "Alias already present in ${RC_FILE}"
        else
            printf '\n# opa: 1Password multi-account wrapper\n%s\n' "${ALIAS_LINE}" >> "${RC_FILE}"
            info "Added to ${RC_FILE}: ${ALIAS_LINE}"
            info "Run 'source ${RC_FILE}' or open a new shell to activate."
        fi
        ;;
    none)
        info "Skipped. Use 'opa' directly, or set up 'op' yourself."
        ;;
    *)
        info "Unrecognised choice '${WIRE_AS_OP}' — skipping. Use 'opa' directly."
        ;;
esac

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────"
echo "Done."
echo ""
echo "Real op binary : ${OP_REAL}"
echo "opa installed  : ${OPA_DEST}"
echo ""
echo "Override the real op path at any time with:"
echo "  export OP_REAL=/path/to/op"
echo ""
echo "Usage:"
echo "  opa read op://work@Engineering/GitHubToken/password"
echo "  opa run --env-file .env -- myapp"
echo ""
echo "In .env files or exports:"
echo "  export MYAPP_SECRET=\"op://work@MyVault/MyItem/password\""
echo "  export OTHER_SECRET=\"op://personal:Private/MyItem/password\""
echo "  export PLAIN=\"op://SharedVault/Item/field\"   # no account, unchanged"
