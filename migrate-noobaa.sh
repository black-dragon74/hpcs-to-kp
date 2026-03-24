#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# --- Configuration ---
NS=${NS:-openshift-storage}
NOOBAA_NAME=${NOOBAA_NAME:-noobaa}
DATA_FILE=${DATA_FILE:-noobaa_key.json}
EXPORTED_DIR=${EXPORTED_DIR:-exported_keys}

# OCS KMS connection details ConfigMap (source of truth for KMS config)
KMS_CONFIGMAP_NAME=${KMS_CONFIGMAP_NAME:-ocs-kms-connection-details}

# Token secret name (auto-detected from NooBaa CR if not set)
TOKEN_SECRET_NAME=${TOKEN_SECRET_NAME:-}

# HPCS (source)
HPCS_INSTANCE_ID=${HPCS_INSTANCE_ID:-}
HPCS_IAM_API_KEY=${HPCS_IAM_API_KEY:-}
HPCS_KEY_ID=${HPCS_KEY_ID:-}
HPCS_URL=${HPCS_URL:-}

# KP (destination)
KP_INSTANCE_ID=${KP_INSTANCE_ID:-}
KP_IAM_API_KEY=${KP_IAM_API_KEY:-}
KP_KEY_ID=${KP_KEY_ID:-}
KP_URL=${KP_URL:-}

# --- Helpers ---

require_data_file() {
  if [[ ! -f "${DATA_FILE}" ]]; then
    log_fatal "Data file ${DATA_FILE} not found. Run phase1 first."
  fi
}

require_exported_dir() {
  if [[ ! -d "${EXPORTED_DIR}" ]]; then
    log_fatal "Exported keys directory ${EXPORTED_DIR} not found. Run phase2 first."
  fi
}

# Auto-detect KMS settings from the NooBaa CR
detect_kms_config() {
  local kms_json
  kms_json=$($(kube_cmd) -n "${NS}" get noobaa "${NOOBAA_NAME}" -o json 2>/dev/null |
    jq -c '.spec.security.kms // empty') || log_fatal "NooBaa CR '${NOOBAA_NAME}' not found in namespace ${NS}"
  if [[ -z "${kms_json}" || "${kms_json}" == "null" ]]; then
    log_fatal "No KMS config found in NooBaa CR '${NOOBAA_NAME}'"
  fi

  local provider
  provider=$(echo "${kms_json}" | jq -r '.connectionDetails.KMS_PROVIDER // empty')
  if [[ -n "${provider}" ]] && [[ "${provider}" != "ibmkeyprotect" ]]; then
    log_warn "KMS_PROVIDER is '${provider}', expected 'ibmkeyprotect'"
  fi

  if [[ -z "${TOKEN_SECRET_NAME}" ]]; then
    TOKEN_SECRET_NAME=$(echo "${kms_json}" | jq -r '.tokenSecretName // empty')
    if [[ -z "${TOKEN_SECRET_NAME}" ]]; then
      log_fatal "Could not detect tokenSecretName from NooBaa CR"
    fi
    log_info "Detected tokenSecretName: ${TOKEN_SECRET_NAME}"
  fi

  if [[ -z "${HPCS_INSTANCE_ID}" ]]; then
    HPCS_INSTANCE_ID=$(echo "${kms_json}" | jq -r '.connectionDetails.IBM_KP_SERVICE_INSTANCE_ID // empty')
    if [[ -n "${HPCS_INSTANCE_ID}" ]]; then
      log_info "Detected HPCS_INSTANCE_ID from NooBaa CR: ${HPCS_INSTANCE_ID}"
    fi
  fi

  if [[ -z "${HPCS_URL}" ]]; then
    HPCS_URL=$(echo "${kms_json}" | jq -r '.connectionDetails.IBM_KP_BASE_URL // empty')
    if [[ -n "${HPCS_URL}" ]]; then
      log_info "Detected HPCS_URL from NooBaa CR: ${HPCS_URL}"
    fi
  fi

  if [[ -z "${HPCS_IAM_API_KEY}" ]]; then
    HPCS_IAM_API_KEY=$($(kube_cmd) -n "${NS}" get secret "${TOKEN_SECRET_NAME}" \
      -o jsonpath='{.data.IBM_KP_SERVICE_API_KEY}' 2>/dev/null | base64 -d)
    if [[ -n "${HPCS_IAM_API_KEY}" ]]; then
      log_info "Detected HPCS_IAM_API_KEY from secret ${TOKEN_SECRET_NAME}"
    fi
  fi
}

# Verify an IAM token is valid against a KMS instance
verify_iam_token() {
  local token="$1" instance_id="$2" base_url="$3" label="$4"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "authorization: Bearer ${token}" \
    -H "bluemix-instance: ${instance_id}" \
    "${base_url}/api/v2/keys?limit=1")

  if [[ "${http_code}" != "200" ]]; then
    log_fatal "IAM token verification failed for ${label} (HTTP ${http_code}). Check API key and instance ID."
  fi
  log_info "IAM token for ${label} verified (HTTP ${http_code})"
}

# List all keys in a KMS instance (handles pagination)
list_kms_keys() {
  local token="$1" instance_id="$2" base_url="$3"
  local offset=0 limit=200 all_keys="[]"

  while true; do
    local response
    response=$(curl -s \
      -H "authorization: Bearer ${token}" \
      -H "bluemix-instance: ${instance_id}" \
      -H "accept: application/vnd.ibm.kms.key+json" \
      "${base_url}/api/v2/keys?limit=${limit}&offset=${offset}")

    local page_keys
    page_keys=$(echo "${response}" | jq -c '.resources // []')
    local count
    count=$(echo "${page_keys}" | jq 'length')

    if [[ "${count}" -eq 0 ]]; then
      break
    fi

    all_keys=$(echo "${all_keys}" "${page_keys}" | jq -s '.[0] + .[1]')
    offset=$((offset + count))

    if [[ "${count}" -lt "${limit}" ]]; then
      break
    fi
  done

  echo "${all_keys}"
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

  if [[ $missing -ne 0 ]]; then
    log_fatal "Prerequisites check failed."
  fi

  detect_kms_config

  # Get NooBaa UID
  local noobaa_uid
  noobaa_uid=$($(kube_cmd) -n "${NS}" get noobaa "${NOOBAA_NAME}" \
    -o jsonpath='{.metadata.uid}' 2>/dev/null) || log_fatal "Cannot read NooBaa CR UID"

  log_info "Current KMS config:"
  log_info "  NooBaa CR:         ${NOOBAA_NAME}"
  log_info "  NooBaa UID:        ${noobaa_uid}"
  log_info "  Key name:          rootkeyb64-${noobaa_uid}"
  log_info "  HPCS Instance ID:  ${HPCS_INSTANCE_ID:-<not set>}"
  log_info "  HPCS URL:          ${HPCS_URL:-<not set>}"
  log_info "  KP Instance ID:    ${KP_INSTANCE_ID:-<not set>}"
  log_info "  KP URL:            ${KP_URL:-<not set>}"
  log_info "  Token secret:      ${TOKEN_SECRET_NAME}"

  log_info "All prerequisites met. Good for phase 1."
}

# --- Phase 1: Inventory — find the NooBaa root key in HPCS ---

phase1_inventory() {
  log_info "Phase 1: Inventory and information gathering"

  detect_kms_config

  if [[ -z "${HPCS_IAM_API_KEY}" ]]; then
    log_fatal "HPCS_IAM_API_KEY must be set (or auto-detected from token secret)"
  fi
  if [[ -z "${HPCS_INSTANCE_ID}" ]]; then
    log_fatal "HPCS_INSTANCE_ID must be set (or auto-detected from NooBaa CR)"
  fi
  if [[ -z "${HPCS_URL}" ]]; then
    log_fatal "HPCS_URL must be set (or auto-detected from NooBaa CR)"
  fi

  # Get NooBaa UID and derive key name
  local noobaa_uid
  noobaa_uid=$($(kube_cmd) -n "${NS}" get noobaa "${NOOBAA_NAME}" \
    -o jsonpath='{.metadata.uid}' 2>/dev/null) || log_fatal "Cannot read NooBaa CR UID"

  local key_name="rootkeyb64-${noobaa_uid}"
  log_info "NooBaa UID: ${noobaa_uid}"
  log_info "Expected key name: ${key_name}"

  # Get IAM token for HPCS
  log_info "Obtaining IAM token for HPCS..."
  local token
  token=$(get_iam_token "${HPCS_IAM_API_KEY}")
  if [[ -z "${token}" || "${token}" == "null" ]]; then
    log_fatal "Failed to obtain IAM token for HPCS"
  fi
  verify_iam_token "${token}" "${HPCS_INSTANCE_ID}" "${HPCS_URL}" "HPCS"

  # List all keys in HPCS and find the one matching our key name
  log_info "Listing keys in HPCS..."
  local all_keys
  all_keys=$(list_kms_keys "${token}" "${HPCS_INSTANCE_ID}" "${HPCS_URL}")

  local key_count
  key_count=$(echo "${all_keys}" | jq 'length')
  log_info "Found ${key_count} key(s) in HPCS"

  # Find key by name
  local key_info
  key_info=$(echo "${all_keys}" | jq -c --arg name "${key_name}" \
    '[.[] | select(.name == $name)] | .[0] // empty')

  if [[ -z "${key_info}" ]]; then
    log_fatal "No key named '${key_name}' found in HPCS"
  fi

  local key_id extractable state
  key_id=$(echo "${key_info}" | jq -r '.id')
  extractable=$(echo "${key_info}" | jq -r '.extractable')
  state=$(echo "${key_info}" | jq -r '.state')

  if [[ "${extractable}" != "true" ]]; then
    log_warn "Key is NOT extractable (Root Key). Cannot migrate payload."
  fi
  if [[ "${state}" != "1" ]]; then
    log_warn "Key is in state ${state} (expected 1=Active)"
  fi

  log_info "Found key: ${key_name} -> ${key_id} (extractable=${extractable}, state=${state})"

  # Save to data file
  jq -n \
    --arg name "${key_name}" \
    --arg uid "${noobaa_uid}" \
    --arg kid "${key_id}" \
    --arg ext "${extractable}" \
    --arg st "${state}" \
    '{
      noobaaUid: $uid,
      keyName: $name,
      keyId: $kid,
      extractable: ($ext == "true"),
      state: ($st | tonumber),
      status: "INVENTORIED"
    }' >"${DATA_FILE}"

  log_info "Phase 1 complete. Data saved to ${DATA_FILE}"
  log_info "You can run phase 2 now."
}

# --- Phase 2: Export key payload from HPCS ---

phase2_export() {
  log_info "Phase 2: Exporting key payload from HPCS"

  require_data_file
  detect_kms_config

  if [[ -z "${HPCS_IAM_API_KEY}" ]]; then
    log_fatal "HPCS_IAM_API_KEY must be set"
  fi
  if [[ -z "${HPCS_INSTANCE_ID}" ]]; then
    log_fatal "HPCS_INSTANCE_ID must be set"
  fi
  if [[ -z "${HPCS_URL}" ]]; then
    log_fatal "HPCS_URL must be set"
  fi

  local status
  status=$(jq -r '.status' "${DATA_FILE}")
  if [[ "${status}" != "INVENTORIED" ]]; then
    log_warn "Key status is '${status}', expected 'INVENTORIED'"
  fi

  local key_id key_name
  key_id=$(jq -r '.keyId' "${DATA_FILE}")
  key_name=$(jq -r '.keyName' "${DATA_FILE}")

  local token
  token=$(get_iam_token "${HPCS_IAM_API_KEY}")
  verify_iam_token "${token}" "${HPCS_INSTANCE_ID}" "${HPCS_URL}" "HPCS"

  log_info "Exporting key: ${key_name} (ID: ${key_id})"

  local response
  response=$(curl -s \
    -H "authorization: Bearer ${token}" \
    -H "bluemix-instance: ${HPCS_INSTANCE_ID}" \
    -H "accept: application/vnd.ibm.kms.key+json" \
    "${HPCS_URL}/api/v2/keys/${key_id}")

  local payload
  payload=$(echo "${response}" | jq -r '.resources[0].payload // empty')

  if [[ -z "${payload}" ]]; then
    log_fatal "No payload returned for ${key_name}. Is this a Root Key?"
  fi

  # Validate payload: should be base64-encoded 32 bytes
  local payload_bytes
  payload_bytes=$(echo "${payload}" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
  if [[ "${payload_bytes}" != "32" ]]; then
    log_warn "Key payload decodes to ${payload_bytes} bytes (expected 32)"
  fi

  mkdir -p "${EXPORTED_DIR}"
  jq -n \
    --arg name "${key_name}" \
    --arg payload "${payload}" \
    --arg keyId "${key_id}" \
    '{name: $name, payload: $payload, sourceKeyId: $keyId}' \
    >"${EXPORTED_DIR}/${key_name}.json"

  # Update data file status
  jq '.status = "EXPORTED"' "${DATA_FILE}" >"${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "${DATA_FILE}"

  log_info "Saved to ${EXPORTED_DIR}/${key_name}.json"
  log_info "Phase 2 complete. You can run phase 3 now."
}

# --- Phase 3: Import key into KP ---

phase3_import() {
  log_info "Phase 3: Importing key into Key Protect"

  require_data_file
  require_exported_dir

  if [[ -z "${KP_IAM_API_KEY}" ]]; then
    log_fatal "KP_IAM_API_KEY must be set"
  fi
  if [[ -z "${KP_INSTANCE_ID}" ]]; then
    log_fatal "KP_INSTANCE_ID must be set"
  fi
  if [[ -z "${KP_URL}" ]]; then
    log_fatal "KP_URL must be set"
  fi

  local key_name
  key_name=$(jq -r '.keyName' "${DATA_FILE}")

  local key_file="${EXPORTED_DIR}/${key_name}.json"
  if [[ ! -f "${key_file}" ]]; then
    log_fatal "Exported key file not found: ${key_file}"
  fi

  local payload
  payload=$(jq -r '.payload' "${key_file}")

  local token
  token=$(get_iam_token "${KP_IAM_API_KEY}")
  verify_iam_token "${token}" "${KP_INSTANCE_ID}" "${KP_URL}" "Key Protect"

  log_info "Importing key: ${key_name}"

  local response http_code body
  response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "authorization: Bearer ${token}" \
    -H "bluemix-instance: ${KP_INSTANCE_ID}" \
    -H "content-type: application/vnd.ibm.kms.key+json" \
    -H "accept: application/vnd.ibm.kms.key+json" \
    "${KP_URL}/api/v2/keys" \
    -d "$(jq -n \
      --arg name "${key_name}" \
      --arg payload "${payload}" \
      '{
        metadata: {
          collectionType: "application/vnd.ibm.kms.key+json",
          collectionTotal: 1
        },
        resources: [{
          type: "application/vnd.ibm.kms.key+json",
          name: $name,
          extractable: true,
          payload: $payload
        }]
      }')")

  http_code=$(echo "${response}" | tail -1)
  body=$(echo "${response}" | sed '$d')

  if [[ "${http_code}" == "201" ]]; then
    local new_id
    new_id=$(echo "${body}" | jq -r '.resources[0].id')
    log_info "Success. New key ID: ${new_id}"

    jq --arg nid "${new_id}" \
      '.status = "IMPORTED" | .destKeyId = $nid' \
      "${DATA_FILE}" >"${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "${DATA_FILE}"
  elif echo "${body}" | grep -q "KEY_ALIAS_NOT_UNIQUE_ERR\|KEY_NAME_NOT_UNIQUE_ERR\|INSTANCE_KEY_RING_KEY_NAME_ALREADY_EXISTS_ERR"; then
    log_info "Key already exists in Key Protect. Skipping."
    jq '.status = "IMPORTED"' \
      "${DATA_FILE}" >"${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "${DATA_FILE}"
  else
    log_fatal "Import FAILED (HTTP ${http_code}): $(echo "${body}" | jq -r '.resources[0].errorMsg // .' 2>/dev/null || echo "${body}")"
  fi

  log_info "Phase 3 complete. You can run phase 4 now."
}

# --- Phase 4: Verify key in KP ---

phase4_verify() {
  log_info "Phase 4: Verifying key in Key Protect"

  require_data_file
  require_exported_dir

  if [[ -z "${KP_IAM_API_KEY}" ]]; then
    log_fatal "KP_IAM_API_KEY must be set"
  fi
  if [[ -z "${KP_INSTANCE_ID}" ]]; then
    log_fatal "KP_INSTANCE_ID must be set"
  fi
  if [[ -z "${KP_URL}" ]]; then
    log_fatal "KP_URL must be set"
  fi

  local key_name
  key_name=$(jq -r '.keyName' "${DATA_FILE}")

  local key_file="${EXPORTED_DIR}/${key_name}.json"
  if [[ ! -f "${key_file}" ]]; then
    log_fatal "Exported key file not found: ${key_file}"
  fi

  local original_payload
  original_payload=$(jq -r '.payload' "${key_file}")

  local token
  token=$(get_iam_token "${KP_IAM_API_KEY}")
  verify_iam_token "${token}" "${KP_INSTANCE_ID}" "${KP_URL}" "Key Protect"

  # NooBaa operator looks up keys by name, so we search the same way
  log_info "Looking up key '${key_name}' in Key Protect..."
  local all_keys
  all_keys=$(list_kms_keys "${token}" "${KP_INSTANCE_ID}" "${KP_URL}")

  local key_info
  key_info=$(echo "${all_keys}" | jq -c --arg name "${key_name}" \
    '[.[] | select(.name == $name)] | .[0] // empty')

  if [[ -z "${key_info}" ]]; then
    log_fatal "Key '${key_name}' not found in Key Protect"
  fi

  local kp_key_id
  kp_key_id=$(echo "${key_info}" | jq -r '.id')
  log_info "Found key in KP: ${kp_key_id}"

  # Fetch payload by key ID
  local response fetched_payload
  response=$(curl -s \
    -H "authorization: Bearer ${token}" \
    -H "bluemix-instance: ${KP_INSTANCE_ID}" \
    -H "accept: application/vnd.ibm.kms.key+json" \
    "${KP_URL}/api/v2/keys/${kp_key_id}")

  fetched_payload=$(echo "${response}" | jq -r '.resources[0].payload // empty')

  if [[ -z "${fetched_payload}" ]]; then
    log_fatal "No payload returned from Key Protect for key ${kp_key_id}"
  fi

  if [[ "${fetched_payload}" == "${original_payload}" ]]; then
    log_info "PASS: payload matches"
    jq '.status = "VERIFIED"' \
      "${DATA_FILE}" >"${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "${DATA_FILE}"
  else
    log_fatal "FAIL: payload mismatch! Original: ${original_payload:0:20}... Fetched: ${fetched_payload:0:20}..."
  fi

  log_info "Phase 4 complete. Key verified. Safe to proceed to phase 5."
}

# --- Phase 5: Update Kubernetes resources (switch to KP) ---

phase5_switch() {
  log_warn "Phase 5: Switching Kubernetes resources to Key Protect"

  require_data_file
  detect_kms_config

  if [[ -z "${KP_IAM_API_KEY}" ]]; then
    log_fatal "KP_IAM_API_KEY must be set"
  fi
  if [[ -z "${KP_INSTANCE_ID}" ]]; then
    log_fatal "KP_INSTANCE_ID must be set"
  fi
  if [[ -z "${KP_URL}" ]]; then
    log_fatal "KP_URL must be set"
  fi
  if [[ -z "${KP_KEY_ID}" ]]; then
    log_fatal "KP_KEY_ID must be set"
  fi

  local status
  status=$(jq -r '.status' "${DATA_FILE}")
  if [[ "${status}" != "VERIFIED" && "${status}" != "IMPORTED" ]]; then
    log_warn "Key status is '${status}'. Consider running phase4 first."
  fi

  # Verify that the KMS ConfigMap already points to KP (set by migrate-osd.sh phase5)
  log_info "Checking KMS ConfigMap ${KMS_CONFIGMAP_NAME}..."
  local cm_iid cm_url
  cm_iid=$($(kube_cmd) -n "${NS}" get configmap "${KMS_CONFIGMAP_NAME}" \
    -o jsonpath='{.data.IBM_KP_SERVICE_INSTANCE_ID}' 2>/dev/null || true)
  cm_url=$($(kube_cmd) -n "${NS}" get configmap "${KMS_CONFIGMAP_NAME}" \
    -o jsonpath='{.data.IBM_KP_BASE_URL}' 2>/dev/null || true)
  if [[ "${cm_iid}" != "${KP_INSTANCE_ID}" ]]; then
    log_fatal "KMS ConfigMap instance ID is '${cm_iid}', expected '${KP_INSTANCE_ID}'. Run migrate-osd.sh phase5 first."
  fi
  if [[ "${cm_url}" != "${KP_URL}" ]]; then
    log_fatal "KMS ConfigMap base URL is '${cm_url}', expected '${KP_URL}'. Run migrate-osd.sh phase5 first."
  fi
  log_info "KMS ConfigMap verified: instance ID and URL point to Key Protect."

  # Verify the NooBaa CR has been reconciled by ocs-operator
  log_info "Checking NooBaa CR ${NOOBAA_NAME}..."
  local noobaa_json cr_iid cr_url
  noobaa_json=$($(kube_cmd) -n "${NS}" get noobaa "${NOOBAA_NAME}" -o json)
  cr_iid=$(echo "${noobaa_json}" | jq -r '.spec.security.kms.connectionDetails.IBM_KP_SERVICE_INSTANCE_ID // empty')
  cr_url=$(echo "${noobaa_json}" | jq -r '.spec.security.kms.connectionDetails.IBM_KP_BASE_URL // empty')
  if [[ "${cr_iid}" != "${KP_INSTANCE_ID}" ]]; then
    log_fatal "NooBaa CR instance ID is '${cr_iid}', expected '${KP_INSTANCE_ID}'. Wait for ocs-operator to reconcile or restart it."
  fi
  if [[ "${cr_url}" != "${KP_URL}" ]]; then
    log_fatal "NooBaa CR base URL is '${cr_url}', expected '${KP_URL}'. Wait for ocs-operator to reconcile or restart it."
  fi
  log_info "NooBaa CR verified: instance ID and URL point to Key Protect."

  log_warn "This will:"
  log_warn "  1. Update the token secret (${TOKEN_SECRET_NAME}) with KP API key and root key"
  log_warn "  2. Restart noobaa-operator to re-reconcile the KMS connection"

  read -rp "Proceed? (yes/no): " confirm
  if [[ "${confirm}" != "yes" ]]; then
    log_info "Phase 5 aborted by user."
    return 1
  fi

  # Step 1: Update token secret (API key + customer root key)
  log_info "Updating token secret ${TOKEN_SECRET_NAME}..."
  $(kube_cmd) -n "${NS}" create secret generic "${TOKEN_SECRET_NAME}" \
    --from-literal=IBM_KP_SERVICE_API_KEY="${KP_IAM_API_KEY}" \
    --from-literal=IBM_KP_CUSTOMER_ROOT_KEY="${KP_KEY_ID}" \
    --dry-run=client -o yaml |
    $(kube_cmd) apply -f -

  # Verify
  local stored_key stored_crk
  stored_key=$($(kube_cmd) -n "${NS}" get secret "${TOKEN_SECRET_NAME}" \
    -o jsonpath='{.data.IBM_KP_SERVICE_API_KEY}' | base64 -d)
  stored_crk=$($(kube_cmd) -n "${NS}" get secret "${TOKEN_SECRET_NAME}" \
    -o jsonpath='{.data.IBM_KP_CUSTOMER_ROOT_KEY}' | base64 -d)
  if [[ "${stored_key}" != "${KP_IAM_API_KEY}" ]]; then
    log_fatal "Token secret API key verification failed!"
  fi
  if [[ "${stored_crk}" != "${KP_KEY_ID}" ]]; then
    log_fatal "Token secret customer root key verification failed!"
  fi
  log_info "Token secret updated and verified (API key + customer root key)."

  # Step 2: Restart noobaa-operator to re-reconcile KMS config
  log_info "Restarting noobaa-operator..."
  $(kube_cmd) -n "${NS}" rollout restart deploy/noobaa-operator
  $(kube_cmd) -n "${NS}" rollout status deploy/noobaa-operator --timeout=120s
  log_info "noobaa-operator restarted."

  # Step 3: Restart noobaa core statefulset to pick up new secret values
  log_info "Restarting noobaa core statefulset..."
  $(kube_cmd) -n "${NS}" rollout restart statefulset -l app=noobaa
  $(kube_cmd) -n "${NS}" rollout status statefulset -l app=noobaa --timeout=120s
  log_info "noobaa core restarted."

  log_info "Phase 5 complete. The noobaa-operator will re-reconcile the KMS connection."
  log_info "Run phase 6 to verify recovery."
}

# --- Phase 6: Verify recovery ---

phase6_verify_recovery() {
  log_info "Phase 6: Verifying NooBaa KMS recovery"

  # Check KMSStatus condition
  log_info "Checking NooBaa KMS conditions..."
  local kms_status kms_type
  kms_status=$($(kube_cmd) -n "${NS}" get noobaa "${NOOBAA_NAME}" -o json 2>/dev/null |
    jq -r '.status.conditions[]? | select(.type=="KMS-Status") | "\(.status)"' 2>/dev/null || echo "<not found>")
  kms_type=$($(kube_cmd) -n "${NS}" get noobaa "${NOOBAA_NAME}" -o json 2>/dev/null |
    jq -r '.status.conditions[]? | select(.type=="KMS-Type") | "\(.status)"' 2>/dev/null || echo "<not found>")

  log_info "  KMSStatus: ${kms_status}"
  log_info "  KMSType:   ${kms_type}"

  if echo "${kms_status}" | grep -qi "error\|invalid"; then
    log_error "KMS status indicates an error. Check operator logs."
  fi

  # Check NooBaa operator pod status
  log_info "NooBaa operator pod status:"
  $(kube_cmd) -n "${NS}" get pods -l app=noobaa --no-headers 2>/dev/null |
    while IFS= read -r line; do log_info "  ${line}"; done

  # Check NooBaa core pod status
  log_info "NooBaa core pod status:"
  $(kube_cmd) -n "${NS}" get pods -l noobaa-core=noobaa --no-headers 2>/dev/null |
    while IFS= read -r line; do log_info "  ${line}"; done

  # Check operator logs for KMS-related messages
  log_info "Recent operator KMS log entries:"
  local kms_logs
  kms_logs=$($(kube_cmd) -n "${NS}" logs deploy/noobaa-operator --tail=100 2>/dev/null |
    grep -i "kms\|rootsecret\|root_secret\|ReconcileRootSecret" || true)
  if [[ -n "${kms_logs}" ]]; then
    echo "${kms_logs}" | tail -20 | while IFS= read -r line; do log_info "  ${line}"; done
  else
    log_info "  No KMS-related log entries found."
  fi

  # Check for errors in operator logs
  local error_lines
  error_lines=$($(kube_cmd) -n "${NS}" logs deploy/noobaa-operator --tail=50 2>/dev/null |
    grep -i "error.*kms\|kms.*error\|KMS Get error\|KMS Set error" || true)
  if [[ -n "${error_lines}" ]]; then
    log_warn "Recent operator KMS errors:"
    echo "${error_lines}" | while IFS= read -r line; do log_warn "  ${line}"; done
  else
    log_info "No recent operator KMS errors."
  fi

  log_info "Phase 6 complete."
  log_info "If something looks out of the ordinary, run rollback to revert back to HPCS."
}

# --- Rollback: Revert to HPCS ---

rollback() {
  log_warn "ROLLBACK: Reverting to HPCS"

  detect_kms_config

  if [[ -z "${HPCS_IAM_API_KEY}" ]]; then
    log_fatal "HPCS_IAM_API_KEY must be set for rollback"
  fi
  if [[ -z "${HPCS_INSTANCE_ID}" ]]; then
    log_fatal "HPCS_INSTANCE_ID must be set for rollback"
  fi
  if [[ -z "${HPCS_URL}" ]]; then
    log_fatal "HPCS_URL must be set for rollback"
  fi
  if [[ -z "${HPCS_KEY_ID}" ]]; then
    log_fatal "HPCS_KEY_ID must be set for rollback"
  fi

  # Verify that the KMS ConfigMap has been reverted (by migrate-osd.sh rollback)
  log_info "Checking KMS ConfigMap ${KMS_CONFIGMAP_NAME}..."
  local cm_iid cm_url
  cm_iid=$($(kube_cmd) -n "${NS}" get configmap "${KMS_CONFIGMAP_NAME}" \
    -o jsonpath='{.data.IBM_KP_SERVICE_INSTANCE_ID}' 2>/dev/null || true)
  cm_url=$($(kube_cmd) -n "${NS}" get configmap "${KMS_CONFIGMAP_NAME}" \
    -o jsonpath='{.data.IBM_KP_BASE_URL}' 2>/dev/null || true)
  if [[ "${cm_iid}" != "${HPCS_INSTANCE_ID}" ]]; then
    log_fatal "KMS ConfigMap instance ID is '${cm_iid}', expected '${HPCS_INSTANCE_ID}'. Run migrate-osd.sh rollback first."
  fi
  if [[ "${cm_url}" != "${HPCS_URL}" ]]; then
    log_fatal "KMS ConfigMap base URL is '${cm_url}', expected '${HPCS_URL}'. Run migrate-osd.sh rollback first."
  fi
  log_info "KMS ConfigMap verified: instance ID and URL point to HPCS."

  # Verify the NooBaa CR has been reconciled back to HPCS
  log_info "Checking NooBaa CR ${NOOBAA_NAME}..."
  local noobaa_json cr_iid cr_url
  noobaa_json=$($(kube_cmd) -n "${NS}" get noobaa "${NOOBAA_NAME}" -o json)
  cr_iid=$(echo "${noobaa_json}" | jq -r '.spec.security.kms.connectionDetails.IBM_KP_SERVICE_INSTANCE_ID // empty')
  cr_url=$(echo "${noobaa_json}" | jq -r '.spec.security.kms.connectionDetails.IBM_KP_BASE_URL // empty')
  if [[ "${cr_iid}" != "${HPCS_INSTANCE_ID}" ]]; then
    log_fatal "NooBaa CR instance ID is '${cr_iid}', expected '${HPCS_INSTANCE_ID}'. Wait for ocs-operator to reconcile or restart it."
  fi
  if [[ "${cr_url}" != "${HPCS_URL}" ]]; then
    log_fatal "NooBaa CR base URL is '${cr_url}', expected '${HPCS_URL}'. Wait for ocs-operator to reconcile or restart it."
  fi
  log_info "NooBaa CR verified: instance ID and URL point to HPCS."

  log_warn "This will revert the token secret to HPCS and restart noobaa-operator."
  read -rp "Proceed with rollback? (yes/no): " confirm
  if [[ "${confirm}" != "yes" ]]; then
    log_info "Rollback aborted by user."
    return 1
  fi

  # Revert token secret (API key + customer root key)
  log_info "Reverting token secret to HPCS values..."
  $(kube_cmd) -n "${NS}" create secret generic "${TOKEN_SECRET_NAME}" \
    --from-literal=IBM_KP_SERVICE_API_KEY="${HPCS_IAM_API_KEY}" \
    --from-literal=IBM_KP_CUSTOMER_ROOT_KEY="${HPCS_KEY_ID}" \
    --dry-run=client -o yaml |
    $(kube_cmd) apply -f -

  # Restart noobaa-operator
  log_info "Restarting noobaa-operator..."
  $(kube_cmd) -n "${NS}" rollout restart deploy/noobaa-operator
  $(kube_cmd) -n "${NS}" rollout status deploy/noobaa-operator --timeout=120s
  log_info "noobaa-operator restarted."

  # Restart noobaa core statefulset
  log_info "Restarting noobaa core statefulset..."
  $(kube_cmd) -n "${NS}" rollout restart statefulset -l app=noobaa
  $(kube_cmd) -n "${NS}" rollout status statefulset -l app=noobaa --timeout=120s
  log_info "noobaa core restarted."

  log_info "Rollback complete."
}

# --- Cleanup ---

cleanup() {
  log_warn "Cleanup: Removing exported key files"
  log_warn "The exported key files contain raw encryption key material."

  read -rp "Delete exported keys and data file? (yes/no): " confirm
  if [[ "${confirm}" != "yes" ]]; then
    log_info "Cleanup aborted by user."
    return 1
  fi

  if [[ -d "${EXPORTED_DIR}" ]]; then
    rm -rf "${EXPORTED_DIR}"
    log_info "Removed ${EXPORTED_DIR}/"
  fi

  if [[ -f "${DATA_FILE}" ]]; then
    rm -f "${DATA_FILE}"
    log_info "Removed ${DATA_FILE}"
  fi

  log_info "Cleanup complete."
  log_info "Keys in HPCS have NOT been deleted. Keep them as fallback."
  log_info "When confident the migration is stable, delete them manually."
}

# --- Main ---

usage() {
  cat <<EOF
Usage: $0 <command>

Migrate the NooBaa root master key from IBM HPCS to IBM Key Protect.
NooBaa stores a single standard key named rootkeyb64-<noobaa-uid> in the KMS.
This script exports that key from HPCS and imports it into Key Protect with the
same name and payload.

Commands:
  check       Check prerequisites and show current KMS config
  phase1      Inventory: find the NooBaa root key in HPCS
  phase2      Export: download the key payload from HPCS
  phase3      Import: upload the key to Key Protect (same name, payload)
  phase4      Verify: confirm the key in Key Protect matches HPCS
  phase5      Switch: update token secret, restart noobaa-operator (requires migrate-osd.sh phase5 first)
  phase6      Verify: check NooBaa KMS conditions and operator health
  rollback    Revert token secret to HPCS (requires migrate-osd.sh rollback first)
  cleanup     Delete exported key files (after successful migration)

Environment variables (auto sourced from .env if it exists):
  LOG_LEVEL             Log level: DEBUG, INFO, WARN, ERROR, FATAL (default: INFO)
  DATA_FILE             JSON tracking file (default: noobaa_key.json)
  EXPORTED_DIR          Directory for exported key files (default: exported_keys)

  NS                    ODF namespace (default: openshift-storage)
  NOOBAA_NAME           NooBaa CR name (default: noobaa)
  KMS_CONFIGMAP_NAME    KMS connection details ConfigMap (default: ocs-kms-connection-details)
  TOKEN_SECRET_NAME     Token secret name (auto-detected from NooBaa CR)

  HPCS_INSTANCE_ID      HPCS instance ID (auto-detected from CR if not set)
  HPCS_IAM_API_KEY      HPCS IAM API key (auto-detected from token secret if not set)
  HPCS_KEY_ID           HPCS customer root key ID (for rollback)
  HPCS_URL              HPCS API URL (auto-detected from CR if not set)

  KP_INSTANCE_ID        Key Protect instance ID
  KP_IAM_API_KEY        Key Protect IAM API key
  KP_KEY_ID             Key Protect customer root key ID
  KP_URL                Key Protect API URL
EOF
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
  check) check_prereqs ;;
  phase1) phase1_inventory ;;
  phase2) phase2_export ;;
  phase3) phase3_import ;;
  phase4) phase4_verify ;;
  phase5) phase5_switch ;;
  phase6) phase6_verify_recovery ;;
  rollback) rollback ;;
  cleanup) cleanup ;;
  *)
    usage
    exit 1
    ;;
  esac
}

load_env

main "$@"
