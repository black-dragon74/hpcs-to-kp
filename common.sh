#!/usr/bin/env bash
# common.sh — shared helpers for migration scripts.
# Source this file; do not execute directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: common.sh must be sourced, not executed directly." >&2
    exit 1
fi

# --- Logging ---
LOG_LEVEL=${LOG_LEVEL:-INFO}

_log_level_num() {
    case "$1" in
    DEBUG) echo 0 ;;
    INFO) echo 1 ;;
    WARN) echo 2 ;;
    ERROR) echo 3 ;;
    FATAL) echo 4 ;;
    *) echo 1 ;;
    esac
}

log() {
    local level="$1"
    shift
    local threshold
    threshold=$(_log_level_num "${LOG_LEVEL}")
    local current
    current=$(_log_level_num "${level}")
    if [[ ${current} -ge ${threshold} ]]; then
        local ts
        ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
        printf '[%s] %-5s %s\n' "${ts}" "${level}" "$*" >&2
    fi
}

log_debug() { log DEBUG "$@"; }
log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; }
log_fatal() {
    log FATAL "$@"
    exit 1
}

# --- Kubernetes helpers ---

kube_cmd() {
    if command -v oc &>/dev/null; then
        echo "oc"
    else
        echo "kubectl"
    fi
}

get_toolbox_pod() {
    local label="${TOOLBOX_LABEL:-app=rook-ceph-tools}"
    $(kube_cmd) -n "${NS}" get pod -l "${label}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

exec_in_toolbox() {
    local pod
    pod=$(get_toolbox_pod)
    $(kube_cmd) -n "${NS}" exec "${pod}" -- bash -c "$*"
}

# --- IAM ---

get_iam_token() {
    local api_key="$1"
    curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${api_key}" |
        jq -r '.access_token'
}

# --- Common prerequisite checks ---

check_common_prereqs() {
    local missing=0

    if ! command -v oc &>/dev/null && ! command -v kubectl &>/dev/null; then
        log_error "oc or kubectl must be installed"
        missing=1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq must be installed"
        missing=1
    fi

    if ! command -v curl &>/dev/null; then
        log_error "curl must be installed"
        missing=1
    fi

    if [[ -z "${KUBECONFIG:-}" ]] && [[ ! -f "$HOME/.kube/config" ]]; then
        log_error "No kubeconfig found (set KUBECONFIG or place at ~/.kube/config)"
        missing=1
    fi

    local pod
    pod=$(get_toolbox_pod)
    if [[ -z "$pod" ]]; then
        log_error "No pod with label ${TOOLBOX_LABEL:-app=rook-ceph-tools} in namespace ${NS}"
        missing=1
    else
        log_info "Found toolbox pod: ${pod}"
    fi

    return ${missing}
}

# --- .env loader ---

load_env() {
    if [ -f .env ]; then
        log_debug "A local .env file exists, loading it.."
        # shellcheck disable=SC1091
        . .env
    fi
}
