#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
NS=${NS:-openshift-storage}
STORAGE_CLASS=${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd-encrypted}
SUBVOLUME_GROUP=${SUBVOLUME_GROUP:-csi}
DATA_FILE=${DATA_FILE:-rbd_volumes.json}
TOOLBOX_LABEL="app=rook-ceph-tools"

# Derived from StorageClass and Ceph (set by resolve_params)
POOL=""
POOL_ID=""
CLUSTER_ID=""
VOLUME_NAME_PREFIX=""

# HPCS configuration
HPCS_INSTANCE_ID=${HPCS_INSTANCE_ID:-}
HPCS_IAM_API_KEY=${HPCS_IAM_API_KEY:-}
HPCS_KEY_ID=${HPCS_KEY_ID:-}
HPCS_URL=${HPCS_URL:-}

# KP configuration
KP_INSTANCE_ID=${KP_INSTANCE_ID:-}
KP_IAM_API_KEY=${KP_IAM_API_KEY:-}
KP_KEY_ID=${KP_KEY_ID:-}
KP_URL=${KP_URL:-}

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

# --- Helpers ---

kube_cmd() {
    if command -v oc &>/dev/null; then
        echo "oc"
    else
        echo "kubectl"
    fi
}

get_toolbox_pod() {
    $(kube_cmd) -n "${NS}" get pod -l "${TOOLBOX_LABEL}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

exec_in_toolbox() {
    local pod
    pod=$(get_toolbox_pod)
    $(kube_cmd) -n "${NS}" exec "${pod}" -- bash -c "$*"
}

get_iam_token() {
    local api_key="$1"
    curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${api_key}" |
        jq -r '.access_token'
}

resolve_storage_class_params() {
    if [[ -z "${STORAGE_CLASS}" ]]; then
        log_fatal "STORAGE_CLASS must be set"
    fi

    local sc_json
    sc_json=$($(kube_cmd) get storageclass "${STORAGE_CLASS}" -o json 2>/dev/null) ||
        log_fatal "StorageClass '${STORAGE_CLASS}' not found"

    POOL=$(echo "${sc_json}" | jq -r '.parameters.pool // empty')
    CLUSTER_ID=$(echo "${sc_json}" | jq -r '.parameters.clusterID // empty')
    VOLUME_NAME_PREFIX=$(echo "${sc_json}" | jq -r '.parameters.volumeNamePrefix // "csi-vol-"')

    if [[ -z "${POOL}" ]]; then
        log_fatal "StorageClass '${STORAGE_CLASS}' has no parameters.pool"
    fi
    if [[ -z "${CLUSTER_ID}" ]]; then
        log_fatal "StorageClass '${STORAGE_CLASS}' has no parameters.clusterID"
    fi

    log_info "Derived from StorageClass: pool=${POOL}, clusterID=${CLUSTER_ID}, volumeNamePrefix=${VOLUME_NAME_PREFIX}"
}

resolve_pool_id() {
    local pool_detail
    pool_detail=$(exec_in_toolbox "ceph osd pool ls detail --format json")

    POOL_ID=$(echo "${pool_detail}" | jq -r --arg pool "${POOL}" '.[] | select(.pool_name == $pool) | .pool_id')

    if [[ -z "${POOL_ID}" ]]; then
        log_fatal "Could not find pool ID for pool '${POOL}'"
    fi

    log_info "Derived pool ID: ${POOL_ID}"
}

resolve_params() {
    resolve_storage_class_params
    resolve_pool_id
}

image_name_from_volume_handle() {
    local volume_handle="$1"
    local uuid="${volume_handle: -36}"

    if ! echo "$uuid" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        log_error "Could not extract a valid UUID from volumeHandle '${volume_handle}'"
        return 1
    fi

    echo "${VOLUME_NAME_PREFIX}${uuid}"
}

list_pvs_for_storage_class() {
    $(kube_cmd) get pv -o json | jq -r --arg sc "${STORAGE_CLASS}" \
        '.items[] | select(.spec.storageClassName == $sc) | select(.spec.csi.volumeHandle != null) | .spec.csi.volumeHandle'
}

# --- Prereqs ---

check_prereqs() {
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

    if [[ -z "${STORAGE_CLASS}" ]]; then
        log_error "STORAGE_CLASS must be set"
        missing=1
    elif ! $(kube_cmd) get storageclass "${STORAGE_CLASS}" &>/dev/null; then
        log_error "StorageClass '${STORAGE_CLASS}' not found in cluster"
        missing=1
    else
        log_info "Found StorageClass: ${STORAGE_CLASS}"
    fi

    local pod
    pod=$(get_toolbox_pod)
    if [[ -z "$pod" ]]; then
        log_error "No pod with label ${TOOLBOX_LABEL} in namespace ${NS}"
        missing=1
    else
        log_info "Found toolbox pod: ${pod}"
    fi

    if [[ $missing -ne 0 ]]; then
        log_fatal "Prerequisites check failed."
    fi
    log_info "All prerequisites met."
}

require_data_file() {
    if [[ ! -f "${DATA_FILE}" ]]; then
        log_fatal "Data file ${DATA_FILE} not found. Run phase1 first."
    fi
}

# --- Phase 1: Discover encrypted RBD volumes and collect DEKs ---

phase1_discover() {
    log_info "Phase 1: Discovering encrypted RBD volumes from StorageClass ${STORAGE_CLASS}"

    resolve_params

    local volume_handles
    volume_handles=$(list_pvs_for_storage_class)
    log_debug "PV volumeHandles: ${volume_handles}"

    echo "{}" >"${DATA_FILE}"

    local count=0 encrypted_count=0

    while IFS= read -r vol_handle; do
        [[ -z "$vol_handle" ]] && continue
        count=$((count + 1))

        local image
        image=$(image_name_from_volume_handle "${vol_handle}")
        if [[ -z "$image" ]]; then
            log_warn "Skipping volumeHandle ${vol_handle}: could not extract image name"
            continue
        fi

        local metadata
        metadata=$(exec_in_toolbox "rbd image-meta list ${POOL}/${image} --format json" 2>/dev/null || echo "{}")
        log_debug "Metadata for ${image}: ${metadata}"

        local is_encrypted
        is_encrypted=$(echo "${metadata}" | jq -r '."rbd.csi.ceph.com/encrypted" // "false"')

        if [[ "${is_encrypted}" == "encrypted" ]]; then
            encrypted_count=$((encrypted_count + 1))
            local dek
            dek=$(echo "${metadata}" | jq -r '."rbd.csi.ceph.com/dek" // ""')

            jq --arg id "${image}" --arg enc "${is_encrypted}" --arg dek "${dek}" \
                --arg vh "${vol_handle}" --arg pool "${POOL}" \
                '.[$id] = {encrypted: $enc, dek: $dek, volumeHandle: $vh, pool: $pool}' \
                "${DATA_FILE}" >"${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "${DATA_FILE}"

            log_info "Encrypted volume found: ${image}"
        else
            log_debug "Skipping unencrypted volume: ${image}, state: ${is_encrypted}"
        fi
    done <<<"${volume_handles}"

    log_info "Phase 1 complete: ${encrypted_count} encrypted out of ${count} total. Data saved to ${DATA_FILE}, you may run phase 2 now"
}

# --- Phase 2: Decrypt DEKs using HPCS Unwrap ---

phase2_unwrap_hpcs() {
    log_info "Phase 2: Decrypting DEKs via HPCS Unwrap"

    require_data_file

    if [[ -z "${HPCS_IAM_API_KEY}" || -z "${HPCS_INSTANCE_ID}" || -z "${HPCS_URL}" || -z "${HPCS_KEY_ID}" ]]; then
        log_fatal "HPCS_IAM_API_KEY, HPCS_INSTANCE_ID, HPCS_URL, and HPCS_KEY_ID must be set"
    fi

    log_debug "Fetching IAM token for HPCS"
    local token
    token=$(get_iam_token "${HPCS_IAM_API_KEY}")

    local volume_ids
    volume_ids=$(jq -r 'keys[]' "${DATA_FILE}")

    while IFS= read -r vol_id; do
        [[ -z "$vol_id" ]] && continue

        local encrypted
        encrypted=$(jq -r --arg id "${vol_id}" '.[$id].encrypted' "${DATA_FILE}")
        [[ "${encrypted}" != "encrypted" ]] && continue

        local dek
        dek=$(jq -r --arg id "${vol_id}" '.[$id].dek' "${DATA_FILE}")

        # DEK in RBD metadata is double-base64-encoded.
        # CephCSI does: base64.DecodeString(encryptedDEK) -> raw bytes -> client.Unwrap()
        # The Go client then base64-encodes those bytes for the API.
        # So the API ciphertext = first-level base64 decoded value (the whole envelope blob).
        local api_ciphertext
        api_ciphertext=$(echo "${dek}" | base64 -d)

        # Check that the volume was encrypted with the expected root key
        local key_handle
        key_handle=$(echo "${api_ciphertext}" | base64 -d | jq -r '.handle')
        if [[ "${key_handle}" != "${HPCS_KEY_ID}" ]]; then
            log_warn "Skipping ${vol_id}: encrypted with key ${key_handle}, expected ${HPCS_KEY_ID}"
            continue
        fi

        # volumeHandle from PV is the CSI volume ID, used as AAD
        local csi_vol
        csi_vol=$(jq -r --arg id "${vol_id}" '.[$id].volumeHandle // empty' "${DATA_FILE}")
        if [[ -z "${csi_vol}" ]]; then
            log_error "No volumeHandle for ${vol_id} in data file. Re-run phase1."
            continue
        fi
        log_debug "CSI volume ID: ${csi_vol}"

        log_info "Unwrapping DEK for ${vol_id}"

        local response
        response=$(curl -s -X POST \
            "${HPCS_URL}/api/v2/keys/${HPCS_KEY_ID}/actions/unwrap" \
            -H "Authorization: Bearer ${token}" \
            -H "Bluemix-Instance: ${HPCS_INSTANCE_ID}" \
            -H "Content-Type: application/vnd.ibm.kms.key_action_unwrap+json" \
            -d "{\"ciphertext\": \"${api_ciphertext}\", \"aad\": [\"${csi_vol}\"]}")

        local plaintext
        plaintext=$(echo "${response}" | jq -r '.plaintext // empty')

        if [[ -z "${plaintext}" ]]; then
            log_error "Failed to unwrap DEK for ${vol_id}: ${response}"
            continue
        fi

        jq --arg id "${vol_id}" --arg pt "${plaintext}" \
            '.[$id].decryptedDek = $pt' \
            "${DATA_FILE}" >"${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "${DATA_FILE}"

        log_debug "Unwrapped DEK for ${vol_id} successfully"
    done <<<"${volume_ids}"

    log_info "Phase 2 complete. Decrypted DEKs stored in ${DATA_FILE}"
}

# --- Phase 3: Re-encrypt DEKs using IBM KP Wrap ---

phase3_wrap_kp() {
    log_info "Phase 3: Wrapping DEKs via IBM Key Protect"

    require_data_file

    if [[ -z "${KP_IAM_API_KEY}" || -z "${KP_INSTANCE_ID}" || -z "${KP_URL}" || -z "${KP_KEY_ID}" ]]; then
        log_fatal "KP_IAM_API_KEY, KP_INSTANCE_ID, KP_URL, and KP_KEY_ID must be set"
    fi

    log_debug "Fetching IAM token for KP"
    local token
    token=$(get_iam_token "${KP_IAM_API_KEY}")

    local volume_ids
    volume_ids=$(jq -r 'keys[]' "${DATA_FILE}")

    while IFS= read -r vol_id; do
        [[ -z "$vol_id" ]] && continue

        local decrypted_dek
        decrypted_dek=$(jq -r --arg id "${vol_id}" '.[$id].decryptedDek // empty' "${DATA_FILE}")

        if [[ -z "${decrypted_dek}" ]]; then
            log_warn "Skipping ${vol_id} - no decrypted DEK"
            continue
        fi

        # volumeHandle from PV is the CSI volume ID, used as AAD
        local csi_vol
        csi_vol=$(jq -r --arg id "${vol_id}" '.[$id].volumeHandle // empty' "${DATA_FILE}")
        if [[ -z "${csi_vol}" ]]; then
            log_error "No volumeHandle for ${vol_id} in data file. Re-run phase1."
            continue
        fi

        log_info "Wrapping DEK for ${vol_id}"

        local response
        response=$(curl -s -X POST \
            "${KP_URL}/api/v2/keys/${KP_KEY_ID}/actions/wrap" \
            -H "Authorization: Bearer ${token}" \
            -H "Bluemix-Instance: ${KP_INSTANCE_ID}" \
            -H "Content-Type: application/vnd.ibm.kms.key_action_wrap+json" \
            -d "{\"plaintext\": \"${decrypted_dek}\", \"aad\": [\"${csi_vol}\"]}")

        local ciphertext
        ciphertext=$(echo "${response}" | jq -r '.ciphertext // empty')

        if [[ -z "${ciphertext}" ]]; then
            log_error "Failed to wrap DEK for ${vol_id}: ${response}"
            continue
        fi

        # KP Wrap returns ciphertext which is the opaque blob.
        # CephCSI stores: base64(base64decode(ciphertext)) in RBD metadata.
        # The Go client's Wrap returns base64-decoded bytes, CephCSI base64-encodes them.
        # For RBD metadata: base64(ciphertext_from_api) = double base64 encoded.
        local kp_encoded
        kp_encoded=$(echo -n "${ciphertext}" | base64)

        jq --arg id "${vol_id}" --arg ct "${kp_encoded}" \
            '.[$id].kpEncrypted = $ct' \
            "${DATA_FILE}" >"${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "${DATA_FILE}"

        log_debug "Wrapped DEK for ${vol_id} successfully"
    done <<<"${volume_ids}"

    log_info "Phase 3 complete. KP-wrapped DEKs stored in ${DATA_FILE}"
}

# --- Phase 4: Update RBD image metadata with new DEKs ---

phase4_update_metadata() {
    log_warn "Phase 4: Updating RBD image metadata (destructive operation)"

    require_data_file

    log_warn "This modifies rbd.csi.ceph.com/dek on encrypted RBD images."
    read -rp "Proceed? (yes/no): " confirm
    if [[ "${confirm}" != "yes" ]]; then
        log_info "Phase 4 aborted by user."
        return 1
    fi

    local volume_ids
    volume_ids=$(jq -r 'keys[]' "${DATA_FILE}")

    while IFS= read -r vol_id; do
        [[ -z "$vol_id" ]] && continue

        local encrypted
        encrypted=$(jq -r --arg id "${vol_id}" '.[$id].encrypted' "${DATA_FILE}")
        [[ "${encrypted}" != "encrypted" ]] && continue

        local kp_encrypted
        kp_encrypted=$(jq -r --arg id "${vol_id}" '.[$id].kpEncrypted // empty' "${DATA_FILE}")

        if [[ -z "${kp_encrypted}" ]]; then
            log_warn "Skipping ${vol_id} - no kpEncrypted value"
            continue
        fi

        local vol_pool
        vol_pool=$(jq -r --arg id "${vol_id}" '.[$id].pool // empty' "${DATA_FILE}")
        if [[ -z "${vol_pool}" ]]; then
            log_error "No pool for ${vol_id} in data file. Re-run phase1."
            continue
        fi

        log_info "Updating metadata for ${vol_id}"
        exec_in_toolbox "rbd image-meta set ${vol_pool}/${vol_id} rbd.csi.ceph.com/dek '${kp_encrypted}'"
        log_debug "Metadata updated for ${vol_id}"
    done <<<"${volume_ids}"

    log_info "Phase 4 complete. RBD metadata updated."
}

# --- Main ---

usage() {
    cat <<EOF
Usage: $0 <command>
    
A helper script to migrate encrypted RBD volumes from IBM HPCS to IBM Key Protect.

Commands:
  check       Check prerequisites
  phase1      Discover encrypted RBD volumes and collect DEKs
  phase2      Decrypt DEKs using HPCS Unwrap
  phase3      Re-encrypt DEKs using IBM Key Protect Wrap
  phase4      Update RBD image metadata with new DEKs (destructive)

Environment variables (auto sourced if a .env file exists):
  LOG_LEVEL           Log level: DEBUG, INFO, WARN, ERROR, FATAL (default: INFO)
  DATA_FILE           JSON output file (default: rbd_volumes.json)

  NS                  Namespace (default: openshift-storage)
  STORAGE_CLASS       Kubernetes StorageClass name (default: ocs-storagecluster-ceph-rbd-encrypted)
                      Pool, pool ID, cluster ID, and volume name prefix are derived automatically.

  HPCS_INSTANCE_ID    HPCS instance ID
  HPCS_IAM_API_KEY    HPCS IAM API key
  HPCS_KEY_ID         HPCS root key ID
  HPCS_URL            HPCS API URL
  
  KP_INSTANCE_ID      Key Protect instance ID
  KP_IAM_API_KEY      Key Protect IAM API key
  KP_KEY_ID           Key Protect root key ID
  KP_URL              Key Protect API URL
EOF
}

main() {
    local cmd="${1:-}"
    case "${cmd}" in
    check) check_prereqs ;;
    phase1)
        check_prereqs
        phase1_discover
        ;;
    phase2) phase2_unwrap_hpcs ;;
    phase3) phase3_wrap_kp ;;
    phase4) phase4_update_metadata ;;
    *)
        usage
        exit 1
        ;;
    esac
}

# Source env if exists
if [ -f .env ]; then
    log_debug "A local .env file exists, loading it.."
    . .env
fi

main "$@"
