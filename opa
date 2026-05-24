#!/usr/bin/env bash
# opa - 1Password CLI wrapper with multi-account op:// URI support
#
# Extends the standard op:// URI scheme with an optional account prefix:
#   op://account@vault/item/[section/]field   (at-sign separator)
#   op://account:vault/item/[section/]field   (colon separator)
#   op://vault/item/field                     (standard, passed through as-is)
#
# @ is tried first; : is used as fallback when no @ is present in the authority.
#
# All op subcommands work as normal. The wrapper only activates when it
# detects extended op:// refs; everything else is passed through untouched.
#
# Real op binary resolution (in order):
#   1. OP_REAL environment variable
#   2. OP_REAL_DEFAULT compiled in by the installer (see install.sh)
#   3. /opt/homebrew/bin/op  (Apple Silicon homebrew default)
#   4. /usr/local/bin/op     (Intel homebrew / manual install default)
#
# Can be used directly as 'opa', or installed as/aliased to 'op'.
# See install.sh for setup options.

set -euo pipefail

# ─── real op binary ──────────────────────────────────────────────────────────

# OP_REAL_DEFAULT is optionally rewritten by install.sh to the detected path.
OP_REAL_DEFAULT=""

find_op() {
    # Priority: env var → installer default → known locations
    if [[ -n "${OP_REAL:-}" ]]; then
        printf '%s' "${OP_REAL}"
        return
    fi
    if [[ -n "${OP_REAL_DEFAULT}" && -x "${OP_REAL_DEFAULT}" ]]; then
        printf '%s' "${OP_REAL_DEFAULT}"
        return
    fi
    for candidate in /opt/homebrew/bin/op /usr/local/bin/op; do
        if [[ -x "${candidate}" ]]; then
            printf '%s' "${candidate}"
            return
        fi
    done
    echo "opa: error: could not find the real 'op' binary." \
      "Set OP_REAL=/path/to/op or re-run install.sh." >&2
    exit 1
}

OP_BIN="$(find_op)"

# ─── URI helpers ─────────────────────────────────────────────────────────────

# is_extended_ref <string>
# True if the string is op://account@vault/... or op://account:vault/...
is_extended_ref() {
    [[ "$1" =~ ^op://([^/]+)/(.+)$ ]] && [[ "${BASH_REMATCH[1]}" == *@* || "${BASH_REMATCH[1]}" == *:* ]]
}

# parse_ref <ref>
# Sets _ACCOUNT and _OP_REF in the caller's scope.
parse_ref() {
    local ref="$1"
    local authority="${ref#op://}"
    authority="${authority%%/*}"
    local item_path="${ref#op://"${authority}"/}"

    local vault
    if [[ "${authority}" == *@* ]]; then
        _ACCOUNT="${authority%%@*}"
        vault="${authority#*@}"
    else
        _ACCOUNT="${authority%%:*}"
        vault="${authority#*:}"
    fi
    _OP_REF="op://${vault}/${item_path}"

    if [[ "${_ACCOUNT}" =~ [^a-zA-Z0-9._@-] ]]; then
        echo "opa: error: unsafe characters in account name '${_ACCOUNT}'" >&2
        exit 1
    fi
}

# ─── argument rewriting ──────────────────────────────────────────────────────

# rewrite_args
# Rewrites extended op:// refs in the global args array in place.
# Prints the account name found, or empty string if none.
rewrite_args() {
    local found_account=""

    for i in "${!args[@]}"; do
        # shellcheck disable=SC2310
        if is_extended_ref "${args[i]}"; then
            local _ACCOUNT _OP_REF
            parse_ref "${args[i]}"
            if [[ -n "${found_account}" && "${found_account}" != "${_ACCOUNT}" ]]; then
                echo "opa: error: refs from multiple accounts ('${found_account}' and '${_ACCOUNT}')" \
                  "in a single invocation. Split into separate commands." >&2
                exit 1
            fi
            found_account="${_ACCOUNT}"
            args[i]="${_OP_REF}"
        fi
    done

    printf '%s' "${found_account}"
}

# rewrite_env_files
# Rewrites extended op:// refs inside --env-file contents.
# Replaces env file paths in the global args array with rewritten temp copies.
# Prints the account name found, or empty string if none.
rewrite_env_files() {
    local found_account=""
    local tmpdir=""

    local i=0
    while [[ ${i} -lt ${#args[@]} ]]; do
        local arg="${args[i]}"
        local env_file=""

        if [[ "${arg}" == "--env-file" && $((i+1)) -lt ${#args[@]} ]]; then
            env_file="${args[i+1]}"
        elif [[ "${arg}" == --env-file=* ]]; then
            env_file="${arg#--env-file=}"
        fi

        if [[ -n "${env_file}" ]]; then
            [[ -f "${env_file}" ]] || { echo "opa: error: env file not found: '${env_file}'" >&2; exit 1; }

            # Check whether this file contains any extended refs before
            # bothering to copy it.
            local needs_rewrite=0
            while IFS= read -r line || [[ -n "${line}" ]]; do
                # shellcheck disable=SC2310
                if [[ "${line}" =~ (op://[^[:space:]\"\'][^[:space:]\"\']*(:[^[:space:]\"\']+)) ]] \
                    && is_extended_ref "${BASH_REMATCH[1]}"; then
                    needs_rewrite=1
                    break
                fi
            done < "${env_file}"

            if [[ ${needs_rewrite} -eq 1 ]]; then
                # Create tmpdir lazily so we only do it when actually needed
                if [[ -z "${tmpdir}" ]]; then
                    tmpdir="$(mktemp -d)"
                    tmpfiles+=("${tmpdir}")
                fi

                local rewritten_file
                rewritten_file="${tmpdir}/$(basename "${env_file}")"

                while IFS= read -r line || [[ -n "${line}" ]]; do
                    # Rewrite any extended ref on this line
                    while [[ "${line}" =~ (op://[^[:space:]\"\']+) ]]; do
                        local ref="${BASH_REMATCH[1]}"
                        # shellcheck disable=SC2310
                        if is_extended_ref "${ref}"; then
                            local _ACCOUNT _OP_REF
                            parse_ref "${ref}"
                            if [[ -n "${found_account}" && "${found_account}" != "${_ACCOUNT}" ]]; then
                                echo "opa: error: refs from multiple accounts" \
                                  "('${found_account}' and '${_ACCOUNT}') in '${env_file}'." \
                                  "Split into separate env files." >&2
                                exit 1
                            fi
                            found_account="${_ACCOUNT}"
                            line="${line/"${ref}"/"${_OP_REF}"}"
                        else
                            break  # plain op:// ref, no further rewriting needed
                        fi
                    done
                    printf '%s\n' "${line}"
                done < "${env_file}" > "${rewritten_file}"

                if [[ "${arg}" == "--env-file" ]]; then
                    args[i+1]="${rewritten_file}"
                else
                    args[i]="--env-file=${rewritten_file}"
                fi
            fi
        fi

        ((i++)) || true
    done

    printf '%s' "${found_account}"
}

# ─── main ────────────────────────────────────────────────────────────────────

args=("$@")
tmpfiles=()
cleanup() { [[ ${#tmpfiles[@]} -eq 0 ]] || rm -rf "${tmpfiles[@]}"; }
trap cleanup EXIT

account_from_args="$(rewrite_args)"
account_from_files="$(rewrite_env_files)"

# Reconcile: both must agree if both found
account=""
if [[ -n "${account_from_args}" && -n "${account_from_files}" \
      && "${account_from_args}" != "${account_from_files}" ]]; then
    echo "opa: error: conflicting accounts between args ('${account_from_args}')" \
      "and env file ('${account_from_files}')" >&2
    exit 1
fi
account="${account_from_args:-${account_from_files}}"

if [[ -n "${account}" ]]; then
    exec "${OP_BIN}" --account "${account}" "${args[@]}"
else
    exec "${OP_BIN}" "${args[@]}"
fi
