#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# --- Configuration ---
NS=${NS:-openshift-storage}
STORAGE_CLASS=${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd-encrypted}
CSI_KMS_CONFIGMAP=${CSI_KMS_CONFIGMAP:-csi-kms-connection-details}
SUBVOLUME_GROUP=${SUBVOLUME_GROUP:-csi}
DATA_FILE=${DATA_FILE:-rbd_volumes.json}
SCALE_STATE_FILE=${SCALE_STATE_FILE:-csi_scale_state.json}
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

# --- Helpers ---

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

  check_common_prereqs || missing=1

  if [[ -z "${STORAGE_CLASS}" ]]; then
    log_error "STORAGE_CLASS must be set"
    missing=1
  elif ! $(kube_cmd) get storageclass "${STORAGE_CLASS}" &>/dev/null; then
    log_error "StorageClass '${STORAGE_CLASS}' not found in cluster"
    missing=1
  else
    log_info "Found StorageClass: ${STORAGE_CLASS}"
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

# --- Phase 5: Update CSI KMS ConfigMap to use KP ---

phase5_update_kms_config() {
  log_info "Phase 5: Updating CSI KMS ConfigMap to use Key Protect"

  # Get encryptionKMSID from StorageClass
  local sc_json
  sc_json=$($(kube_cmd) get storageclass "${STORAGE_CLASS}" -o json 2>/dev/null) ||
    log_fatal "StorageClass '${STORAGE_CLASS}' not found"

  local kms_id
  kms_id=$(echo "${sc_json}" | jq -r '.parameters.encryptionKMSID // empty')
  if [[ -z "${kms_id}" ]]; then
    log_fatal "StorageClass '${STORAGE_CLASS}' has no parameters.encryptionKMSID"
  fi
  log_info "Found encryptionKMSID: ${kms_id}"

  # Read the CSI KMS ConfigMap
  local cm_json
  cm_json=$($(kube_cmd) -n "${NS}" get configmap "${CSI_KMS_CONFIGMAP}" -o json 2>/dev/null) ||
    log_fatal "ConfigMap '${CSI_KMS_CONFIGMAP}' not found in namespace '${NS}'"

  # Check that the key exists in the ConfigMap
  local existing_entry
  existing_entry=$(echo "${cm_json}" | jq -r --arg key "${kms_id}" '.data[$key] // empty')
  if [[ -z "${existing_entry}" ]]; then
    log_fatal "Key '${kms_id}' not found in ConfigMap '${CSI_KMS_CONFIGMAP}'"
  fi
  log_info "Existing KMS entry for '${kms_id}':"
  echo "${existing_entry}" | jq .

  # Ask for KP secret name
  read -rp "Enter the KP secret name to use (e.g. ibm-kp-secret): " kp_secret_name
  if [[ -z "${kp_secret_name}" ]]; then
    log_fatal "KP secret name cannot be empty"
  fi

  # Validate KP env vars
  if [[ -z "${KP_INSTANCE_ID}" || -z "${KP_IAM_API_KEY}" || -z "${KP_KEY_ID}" || -z "${KP_URL}" ]]; then
    log_fatal "KP_INSTANCE_ID, KP_IAM_API_KEY, KP_KEY_ID, and KP_URL must be set"
  fi

  # Build the new KMS entry for KP
  local new_kms_entry
  new_kms_entry=$(jq -n \
    --arg provider "ibmkeyprotect" \
    --arg svc_name "${kms_id}" \
    --arg instance_id "${KP_INSTANCE_ID}" \
    --arg secret_name "${kp_secret_name}" \
    --arg base_url "${KP_URL}" \
    --arg token_url "https://iam.cloud.ibm.com/identity/token" \
    '{
      KMS_PROVIDER: $provider,
      KMS_SERVICE_NAME: $svc_name,
      IBM_KP_SERVICE_INSTANCE_ID: $instance_id,
      IBM_KP_SECRET_NAME: $secret_name,
      IBM_KP_BASE_URL: $base_url,
      IBM_KP_TOKEN_URL: $token_url
    }')

  # Build the KP secret data
  local encoded_api_key
  encoded_api_key=$(echo -n "${KP_IAM_API_KEY}" | base64)
  local encoded_root_key
  encoded_root_key=$(echo -n "${KP_KEY_ID}" | base64)

  # Show summary
  echo ""
  log_warn "=== Phase 5 Summary ==="
  echo ""
  echo "ConfigMap: ${CSI_KMS_CONFIGMAP} (namespace: ${NS})"
  echo ""
  echo "1. Create Secret '${kp_secret_name}' in namespace '${NS}' with:"
  echo "   - IBM_KP_SERVICE_API_KEY: (from KP_IAM_API_KEY)"
  echo "   - IBM_KP_CUSTOMER_ROOT_KEY: (from KP_KEY_ID)"
  echo ""
  echo "2. Rename ConfigMap key '${kms_id}' -> '${kms_id}-orig'"
  echo ""
  echo "3. Create new ConfigMap key '${kms_id}' with KP config:"
  echo "${new_kms_entry}" | jq .
  echo ""

  read -rp "Proceed? (yes/no): " confirm
  if [[ "${confirm}" != "yes" ]]; then
    log_info "Phase 5 aborted by user."
    return 1
  fi

  # Step 1: Create the KP secret
  log_info "Creating secret '${kp_secret_name}' in namespace '${NS}'"
  $(kube_cmd) -n "${NS}" create secret generic "${kp_secret_name}" \
    --from-literal="IBM_KP_SERVICE_API_KEY=${KP_IAM_API_KEY}" \
    --from-literal="IBM_KP_CUSTOMER_ROOT_KEY=${KP_KEY_ID}" \
    --dry-run=client -o yaml | $(kube_cmd) apply -f -

  # Step 2: Rename existing key to -orig
  log_info "Renaming ConfigMap key '${kms_id}' to '${kms_id}-orig'"
  local existing_value
  existing_value=$($(kube_cmd) -n "${NS}" get configmap "${CSI_KMS_CONFIGMAP}" -o jsonpath="{.data.${kms_id}}")
  $(kube_cmd) -n "${NS}" patch configmap "${CSI_KMS_CONFIGMAP}" \
    --type=json \
    -p "[{\"op\": \"add\", \"path\": \"/data/${kms_id}-orig\", \"value\": $(echo -n "${existing_value}" | jq -Rs .)}]"

  # Step 3: Replace the original key with KP config
  log_info "Setting ConfigMap key '${kms_id}' to KP configuration"
  local new_kms_compact
  new_kms_compact=$(echo "${new_kms_entry}" | jq -c .)
  $(kube_cmd) -n "${NS}" patch configmap "${CSI_KMS_CONFIGMAP}" \
    --type=json \
    -p "[{\"op\": \"replace\", \"path\": \"/data/${kms_id}\", \"value\": $(echo -n "${new_kms_compact}" | jq -Rs .)}]"

  log_info "Phase 5 complete. CSI KMS ConfigMap updated and KP secret created."
  log_info "The PVC mounts should now complete without any errors."
}

# --- Pre/Post: Scale CSI provisioners ---

detect_csi_mode() {
  local operator_deps
  operator_deps=$($(kube_cmd) -n "${NS}" get deployment -l app.kubernetes.io/name=ceph-csi-operator -o name 2>/dev/null || true)

  if [[ -n "${operator_deps}" ]]; then
    echo "operator"
    return
  fi

  local rook_deps
  rook_deps=$($(kube_cmd) -n "${NS}" get deployment -o name 2>/dev/null | grep 'csi-rbdplugin-provisioner' || true)

  if [[ -n "${rook_deps}" ]]; then
    echo "rook"
    return
  fi

  echo ""
}

save_and_scale_deployment() {
  local deploy="$1"
  local name
  name=$(basename "${deploy}")

  local replicas
  replicas=$($(kube_cmd) -n "${NS}" get "${deploy}" -o jsonpath='{.spec.replicas}' 2>/dev/null)

  jq --arg name "${name}" --argjson replicas "${replicas:-0}" \
    '.deployments[$name] = $replicas' \
    "${SCALE_STATE_FILE}" >"${SCALE_STATE_FILE}.tmp" && mv "${SCALE_STATE_FILE}.tmp" "${SCALE_STATE_FILE}"

  log_info "Scaling ${name} from ${replicas} to 0"
  $(kube_cmd) -n "${NS}" scale "${deploy}" --replicas=0
}

pre_scale_down() {
  log_info "Pre: Scaling down CSI provisioner deployments"

  local mode
  mode=$(detect_csi_mode)

  if [[ -z "${mode}" ]]; then
    log_fatal "Could not detect CSI mode (no ceph-csi-operator or rook csi-rbdplugin-provisioner deployments found in ${NS})"
  fi

  log_info "Detected CSI mode: ${mode}"

  jq -n --arg mode "${mode}" '{mode: $mode, deployments: {}}' >"${SCALE_STATE_FILE}"

  if [[ "${mode}" == "operator" ]]; then
    # Scale down the operator first
    local operator_deps
    operator_deps=$($(kube_cmd) -n "${NS}" get deployment -l app.kubernetes.io/name=ceph-csi-operator -o name 2>/dev/null)

    while IFS= read -r deploy; do
      [[ -z "${deploy}" ]] && continue
      save_and_scale_deployment "${deploy}"
    done <<<"${operator_deps}"

    # Wait for operator to scale down before scaling controller plugins
    log_info "Waiting for operator to scale down..."
    sleep 5

    # Scale down all ctrlplugin deployments
    local ctrl_deps
    ctrl_deps=$($(kube_cmd) -n "${NS}" get deployment -o name 2>/dev/null | grep 'csi\.ceph\.com-ctrlplugin$' || true)

    while IFS= read -r deploy; do
      [[ -z "${deploy}" ]] && continue
      save_and_scale_deployment "${deploy}"
    done <<<"${ctrl_deps}"

  elif [[ "${mode}" == "rook" ]]; then
    local rook_deps
    rook_deps=$($(kube_cmd) -n "${NS}" get deployment -o name 2>/dev/null | grep 'csi-rbdplugin-provisioner' || true)

    while IFS= read -r deploy; do
      [[ -z "${deploy}" ]] && continue
      save_and_scale_deployment "${deploy}"
    done <<<"${rook_deps}"
  fi

  log_info "Pre complete. Scale state saved to ${SCALE_STATE_FILE}"
}

post_scale_up() {
  log_info "Post: Restoring CSI provisioner deployments"

  if [[ ! -f "${SCALE_STATE_FILE}" ]]; then
    log_fatal "Scale state file ${SCALE_STATE_FILE} not found. Run 'pre' first."
  fi

  local mode
  mode=$(jq -r '.mode' "${SCALE_STATE_FILE}")

  local names
  names=$(jq -r '.deployments | keys[]' "${SCALE_STATE_FILE}")

  # For operator mode, restore ctrlplugins first, then operator
  # (reverse order of scale-down)
  if [[ "${mode}" == "operator" ]]; then
    # Restore ctrlplugin deployments first
    while IFS= read -r name; do
      [[ -z "${name}" ]] && continue
      echo "${name}" | grep -q 'csi\.ceph\.com-ctrlplugin$' || continue

      local replicas
      replicas=$(jq -r --arg name "${name}" '.deployments[$name]' "${SCALE_STATE_FILE}")
      log_info "Restoring deployment/${name} to ${replicas} replicas"
      $(kube_cmd) -n "${NS}" scale "deployment/${name}" --replicas="${replicas}"
    done <<<"${names}"

    # Then restore operator
    while IFS= read -r name; do
      [[ -z "${name}" ]] && continue
      echo "${name}" | grep -q 'csi\.ceph\.com-ctrlplugin$' && continue

      local replicas
      replicas=$(jq -r --arg name "${name}" '.deployments[$name]' "${SCALE_STATE_FILE}")
      log_info "Restoring deployment/${name} to ${replicas} replicas"
      $(kube_cmd) -n "${NS}" scale "deployment/${name}" --replicas="${replicas}"
    done <<<"${names}"
  else
    while IFS= read -r name; do
      [[ -z "${name}" ]] && continue

      local replicas
      replicas=$(jq -r --arg name "${name}" '.deployments[$name]' "${SCALE_STATE_FILE}")
      log_info "Restoring deployment/${name} to ${replicas} replicas"
      $(kube_cmd) -n "${NS}" scale "deployment/${name}" --replicas="${replicas}"
    done <<<"${names}"
  fi

  log_info "Post complete. All deployments restored."
}

# --- Main ---

usage() {
  cat <<EOF
Usage: $0 <command>

A helper script to migrate encrypted RBD volumes from IBM HPCS to IBM Key Protect.

Commands:
  check       Check prerequisites
  pre         Scale down CSI provisioner deployments (run before migration)
  phase1      Discover encrypted RBD volumes and collect DEKs
  phase2      Decrypt DEKs using HPCS Unwrap
  phase3      Re-encrypt DEKs using IBM Key Protect Wrap
  phase4      Update RBD image metadata with new DEKs (destructive)
  phase5      Update CSI KMS ConfigMap to use Key Protect (destructive)
  post        Restore CSI provisioner deployments (run after migration)

Environment variables (auto sourced if a .env file exists):
  LOG_LEVEL           Log level: DEBUG, INFO, WARN, ERROR, FATAL (default: INFO)
  DATA_FILE           JSON output file (default: rbd_volumes.json)
  SCALE_STATE_FILE    Scale state file for pre/post (default: csi_scale_state.json)

  NS                  Namespace (default: openshift-storage)
  STORAGE_CLASS       Kubernetes StorageClass name (default: ocs-storagecluster-ceph-rbd-encrypted)
                      Pool, pool ID, cluster ID, and volume name prefix are derived automatically.
  CSI_KMS_CONFIGMAP   CSI KMS ConfigMap name (default: csi-kms-connection-details)

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
  pre) pre_scale_down ;;
  phase1) phase1_discover ;;
  phase2) phase2_unwrap_hpcs ;;
  phase3) phase3_wrap_kp ;;
  phase4) phase4_update_metadata ;;
  phase5) phase5_update_kms_config ;;
  post) post_scale_up ;;
  *)
    usage
    exit 1
    ;;
  esac
}

load_env

main "$@"
