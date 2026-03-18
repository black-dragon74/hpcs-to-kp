#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# --- Configuration ---
NS=${NS:-openshift-storage}
TOOLBOX_LABEL="${TOOLBOX_LABEL:-app=rook-ceph-tools}"
DATA_FILE=${DATA_FILE:-osd_keys.json}
EXPORTED_DIR=${EXPORTED_DIR:-exported_keys}

# CephCluster CR name
CEPH_CLUSTER_NAME=${CEPH_CLUSTER_NAME:-ocs-storagecluster-cephcluster}

# OCS KMS connection details ConfigMap (source of truth for KMS config)
KMS_CONFIGMAP_NAME=${KMS_CONFIGMAP_NAME:-ocs-kms-connection-details}

# Token secret name (auto-detected from CephCluster CR if not set)
TOKEN_SECRET_NAME=${TOKEN_SECRET_NAME:-}

# HPCS (source) — reuses same env vars as migrate-csi.sh
HPCS_INSTANCE_ID=${HPCS_INSTANCE_ID:-}
HPCS_IAM_API_KEY=${HPCS_IAM_API_KEY:-}
HPCS_URL=${HPCS_URL:-}

# KP (destination) — reuses same env vars as migrate-csi.sh
KP_INSTANCE_ID=${KP_INSTANCE_ID:-}
KP_IAM_API_KEY=${KP_IAM_API_KEY:-}
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

# Auto-detect KMS settings from the CephCluster CR
detect_kms_config() {
    local security_json
    security_json=$($(kube_cmd) -n "${NS}" get cephcluster "${CEPH_CLUSTER_NAME}" \
        -o jsonpath='{.spec.security}' 2>/dev/null) || log_fatal "CephCluster '${CEPH_CLUSTER_NAME}' not found in namespace ${NS}"

    local provider
    provider=$(echo "${security_json}" | jq -r '.kms.connectionDetails.KMS_PROVIDER // empty')
    if [[ -n "${provider}" ]] && [[ "${provider}" != "ibmkeyprotect" ]]; then
        log_warn "KMS_PROVIDER is '${provider}', expected 'ibmkeyprotect'"
    fi

    if [[ -z "${TOKEN_SECRET_NAME}" ]]; then
        TOKEN_SECRET_NAME=$(echo "${security_json}" | jq -r '.kms.tokenSecretName // empty')
        if [[ -z "${TOKEN_SECRET_NAME}" ]]; then
            log_fatal "Could not detect tokenSecretName from CephCluster CR"
        fi
        log_info "Detected tokenSecretName: ${TOKEN_SECRET_NAME}"
    fi

    # Auto-fill HPCS settings from the live cluster if not explicitly set
    if [[ -z "${HPCS_INSTANCE_ID}" ]]; then
        HPCS_INSTANCE_ID=$(echo "${security_json}" | jq -r '.kms.connectionDetails.IBM_KP_SERVICE_INSTANCE_ID // empty')
        if [[ -n "${HPCS_INSTANCE_ID}" ]]; then
            log_info "Detected HPCS_INSTANCE_ID from CephCluster: ${HPCS_INSTANCE_ID}"
        fi
    fi

    if [[ -z "${HPCS_URL}" ]]; then
        HPCS_URL=$(echo "${security_json}" | jq -r '.kms.connectionDetails.IBM_KP_BASE_URL // empty')
        if [[ -n "${HPCS_URL}" ]]; then
            log_info "Detected HPCS_URL from CephCluster: ${HPCS_URL}"
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

    check_common_prereqs || missing=1

    if [[ $missing -ne 0 ]]; then
        log_fatal "Prerequisites check failed."
    fi

    detect_kms_config

    log_info "Current KMS config:"
    log_info "  HPCS Instance ID:  ${HPCS_INSTANCE_ID:-<not set>}"
    log_info "  HPCS URL:          ${HPCS_URL:-<not set>}"
    log_info "  KP Instance ID:    ${KP_INSTANCE_ID:-<not set>}"
    log_info "  KP URL:            ${KP_URL:-<not set>}"
    log_info "  Token secret:      ${TOKEN_SECRET_NAME}"
    log_info "  CephCluster:       ${CEPH_CLUSTER_NAME}"

    # Record cluster health
    log_info "Ceph cluster status:"
    exec_in_toolbox "ceph status" 2>&1 | while IFS= read -r line; do log_info "  ${line}"; done
    exec_in_toolbox "ceph osd tree" 2>&1 | while IFS= read -r line; do log_info "  ${line}"; done

    log_info "All prerequisites met. Good for phase 1."
}

# --- Phase 1: Inventory — list OSD PVCs and keys in HPCS ---

phase1_inventory() {
    log_info "Phase 1: Inventory and information gathering"

    detect_kms_config

    if [[ -z "${HPCS_IAM_API_KEY}" ]]; then
        log_fatal "HPCS_IAM_API_KEY must be set (or auto-detected from token secret)"
    fi
    if [[ -z "${HPCS_INSTANCE_ID}" ]]; then
        log_fatal "HPCS_INSTANCE_ID must be set (or auto-detected from CephCluster CR)"
    fi
    if [[ -z "${HPCS_URL}" ]]; then
        log_fatal "HPCS_URL must be set (or auto-detected from CephCluster CR)"
    fi

    # Get encrypted device set names from CephCluster CR
    log_info "Reading encrypted device sets from CephCluster CR..."
    local encrypted_sets
    encrypted_sets=$($(kube_cmd) -n "${NS}" get cephcluster "${CEPH_CLUSTER_NAME}" \
        -o json | jq -r '.spec.storage.storageClassDeviceSets[]? | select(.encrypted == true) | .name')

    if [[ -z "${encrypted_sets}" ]]; then
        log_fatal "No encrypted storageClassDeviceSets found in CephCluster '${CEPH_CLUSTER_NAME}'"
    fi
    log_info "Encrypted device sets:"
    echo "${encrypted_sets}" | while IFS= read -r ds; do log_info "  ${ds}"; done

    # Get PVC names from OSD deployments (label ceph.rook.io/pvc holds the PVC claim name)
    # Filter to only deployments belonging to encrypted device sets
    log_info "Listing OSD deployments and PVC mappings..."
    local deploy_json
    deploy_json=$($(kube_cmd) -n "${NS}" get deploy -l app=rook-ceph-osd -o json 2>/dev/null)

    local pvc_list=""
    while IFS= read -r ds_name; do
        [[ -z "${ds_name}" ]] && continue
        local ds_pvcs
        ds_pvcs=$(echo "${deploy_json}" | jq -r \
            --arg ds "${ds_name}" \
            '.items[] | select(.metadata.labels["ceph.rook.io/DeviceSet"] == $ds) | .metadata.labels["ceph.rook.io/pvc"]')
        if [[ -n "${ds_pvcs}" ]]; then
            while IFS= read -r pvc; do
                local deploy_name
                deploy_name=$(echo "${deploy_json}" | jq -r \
                    --arg pvc "${pvc}" \
                    '.items[] | select(.metadata.labels["ceph.rook.io/pvc"] == $pvc) | .metadata.name')
                log_info "  ${deploy_name} -> ${pvc} (device set: ${ds_name})"
            done <<<"${ds_pvcs}"
            if [[ -z "${pvc_list}" ]]; then
                pvc_list="${ds_pvcs}"
            else
                pvc_list="${pvc_list}"$'\n'"${ds_pvcs}"
            fi
        fi
    done <<<"${encrypted_sets}"

    if [[ -z "${pvc_list}" ]]; then
        log_fatal "No OSD PVCs found for encrypted device sets"
    fi

    local pvc_count
    pvc_count=$(echo "${pvc_list}" | wc -l | tr -d ' ')
    log_info "Found ${pvc_count} encrypted OSD PVC(s)"

    # Get IAM token for HPCS
    log_info "Obtaining IAM token for HPCS..."
    local token
    token=$(get_iam_token "${HPCS_IAM_API_KEY}")
    if [[ -z "${token}" || "${token}" == "null" ]]; then
        log_fatal "Failed to obtain IAM token for HPCS"
    fi
    verify_iam_token "${token}" "${HPCS_INSTANCE_ID}" "${HPCS_URL}" "HPCS"

    # List all keys in HPCS
    log_info "Listing keys in HPCS..."
    local all_keys
    all_keys=$(list_kms_keys "${token}" "${HPCS_INSTANCE_ID}" "${HPCS_URL}")

    local key_count
    key_count=$(echo "${all_keys}" | jq 'length')
    log_info "Found ${key_count} key(s) in HPCS"

    # Build data file: map PVC names to key IDs
    local data="{}"

    while IFS= read -r pvc_name; do
        [[ -z "${pvc_name}" ]] && continue
        pvc_name=$(echo "${pvc_name}" | tr -d ' ')

        # Find matching key by alias (Rook uses PVC name as alias)
        local key_info
        key_info=$(echo "${all_keys}" | jq -c --arg alias "${pvc_name}" \
            '[.[] | select(.aliases != null) | select(.aliases[] == $alias)] | .[0] // empty')

        if [[ -z "${key_info}" ]]; then
            # Fallback: match by name
            key_info=$(echo "${all_keys}" | jq -c --arg name "${pvc_name}" \
                '[.[] | select(.name == $name)] | .[0] // empty')
        fi

        if [[ -z "${key_info}" ]]; then
            log_error "No key found in HPCS for PVC: ${pvc_name}"
            data=$(echo "${data}" | jq --arg pvc "${pvc_name}" \
                '.[$pvc] = {status: "MISSING", keyId: null, extractable: null}')
            continue
        fi

        local key_id extractable state key_name
        key_id=$(echo "${key_info}" | jq -r '.id')
        extractable=$(echo "${key_info}" | jq -r '.extractable')
        state=$(echo "${key_info}" | jq -r '.state')
        key_name=$(echo "${key_info}" | jq -r '.name')

        if [[ "${extractable}" != "true" ]]; then
            log_warn "Key for PVC ${pvc_name} is NOT extractable (Root Key). Cannot migrate payload."
        fi
        if [[ "${state}" != "1" ]]; then
            log_warn "Key for PVC ${pvc_name} is in state ${state} (expected 1=Active)"
        fi

        data=$(echo "${data}" | jq \
            --arg pvc "${pvc_name}" \
            --arg kid "${key_id}" \
            --arg ext "${extractable}" \
            --arg st "${state}" \
            --arg kn "${key_name}" \
            '.[$pvc] = {status: "INVENTORIED", keyId: $kid, extractable: ($ext == "true"), state: ($st | tonumber), keyName: $kn}')

        log_info "  ${pvc_name} -> key ${key_id} (extractable=${extractable}, state=${state})"
    done <<<"${pvc_list}"

    echo "${data}" | jq '.' >"${DATA_FILE}"

    # Summary
    local missing_count
    missing_count=$(jq '[.[] | select(.status == "MISSING")] | length' "${DATA_FILE}")
    local inventoried_count
    inventoried_count=$(jq '[.[] | select(.status == "INVENTORIED")] | length' "${DATA_FILE}")

    log_info "Phase 1 complete: ${inventoried_count} key(s) found, ${missing_count} missing. Data saved to ${DATA_FILE}"
    log_info "You can run phase 2 now."

    if [[ "${missing_count}" -gt 0 ]]; then
        log_error "Some PVCs have no matching key in HPCS. Investigate before proceeding."
    fi
}

# --- Phase 2: Export key payloads from HPCS ---

phase2_export() {
    log_info "Phase 2: Exporting key payloads from HPCS"

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

    local token
    token=$(get_iam_token "${HPCS_IAM_API_KEY}")
    verify_iam_token "${token}" "${HPCS_INSTANCE_ID}" "${HPCS_URL}" "HPCS"

    mkdir -p "${EXPORTED_DIR}"

    local volume_ids
    volume_ids=$(jq -r 'keys[]' "${DATA_FILE}")
    local export_count=0 fail_count=0

    while IFS= read -r pvc_name; do
        [[ -z "${pvc_name}" ]] && continue

        local status
        status=$(jq -r --arg pvc "${pvc_name}" '.[$pvc].status' "${DATA_FILE}")
        if [[ "${status}" != "INVENTORIED" ]]; then
            log_warn "Skipping ${pvc_name} (status: ${status})"
            continue
        fi

        local key_id
        key_id=$(jq -r --arg pvc "${pvc_name}" '.[$pvc].keyId' "${DATA_FILE}")

        log_info "Exporting key: ${pvc_name} (ID: ${key_id})"

        local response
        response=$(curl -s \
            -H "authorization: Bearer ${token}" \
            -H "bluemix-instance: ${HPCS_INSTANCE_ID}" \
            -H "accept: application/vnd.ibm.kms.key+json" \
            "${HPCS_URL}/api/v2/keys/${key_id}")

        local payload aliases
        payload=$(echo "${response}" | jq -r '.resources[0].payload // empty')
        aliases=$(echo "${response}" | jq -c '.resources[0].aliases // []')

        if [[ -z "${payload}" ]]; then
            log_error "No payload returned for ${pvc_name}. Is this a Root Key?"
            fail_count=$((fail_count + 1))
            continue
        fi

        jq -n \
            --arg name "${pvc_name}" \
            --arg payload "${payload}" \
            --argjson aliases "${aliases}" \
            --arg keyId "${key_id}" \
            '{name: $name, payload: $payload, aliases: $aliases, sourceKeyId: $keyId}' \
            >"${EXPORTED_DIR}/${pvc_name}.json"

        # Update data file status
        jq --arg pvc "${pvc_name}" \
            '.[$pvc].status = "EXPORTED"' \
            "${DATA_FILE}" >"${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "${DATA_FILE}"

        export_count=$((export_count + 1))
        log_debug "Saved to ${EXPORTED_DIR}/${pvc_name}.json"
    done <<<"${volume_ids}"

    log_info "Phase 2 complete: ${export_count} exported, ${fail_count} failed. You can run phase 3 now."

    if [[ "${fail_count}" -gt 0 ]]; then
        log_error "Some keys failed to export. Do NOT proceed until all keys are exported."
    fi
}

# --- Phase 3: Import keys into KP ---

phase3_import() {
    log_info "Phase 3: Importing keys into Key Protect"

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

    local token
    token=$(get_iam_token "${KP_IAM_API_KEY}")
    verify_iam_token "${token}" "${KP_INSTANCE_ID}" "${KP_URL}" "Key Protect"

    # Check for existing keys in KP
    local existing_count
    existing_count=$(curl -s \
        -H "authorization: Bearer ${token}" \
        -H "bluemix-instance: ${KP_INSTANCE_ID}" \
        -H "accept: application/vnd.ibm.kms.key+json" \
        "${KP_URL}/api/v2/keys?limit=1" |
        jq '.metadata.collectionTotal // 0')
    log_info "Key Protect currently has ${existing_count} key(s)"

    local import_count=0 skip_count=0 fail_count=0

    for key_file in "${EXPORTED_DIR}"/*.json; do
        [[ ! -f "${key_file}" ]] && continue

        local key_name payload
        key_name=$(jq -r '.name' "${key_file}")
        payload=$(jq -r '.payload' "${key_file}")

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
                        payload: $payload,
                        aliases: [$name]
                    }]
                }')")

        http_code=$(echo "${response}" | tail -1)
        body=$(echo "${response}" | sed '$d')

        if [[ "${http_code}" == "201" ]]; then
            local new_id
            new_id=$(echo "${body}" | jq -r '.resources[0].id')
            log_info "  Success. New key ID: ${new_id}"

            jq --arg pvc "${key_name}" --arg nid "${new_id}" \
                '.[$pvc].status = "IMPORTED" | .[$pvc].destKeyId = $nid' \
                "${DATA_FILE}" >"${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "${DATA_FILE}"

            import_count=$((import_count + 1))
        elif echo "${body}" | grep -q "KEY_ALIAS_NOT_UNIQUE_ERR"; then
            log_info "  Key already exists in Key Protect (alias not unique). Skipping."
            jq --arg pvc "${key_name}" \
                '.[$pvc].status = "IMPORTED"' \
                "${DATA_FILE}" >"${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "${DATA_FILE}"
            skip_count=$((skip_count + 1))
        else
            log_error "  FAILED (HTTP ${http_code}):"
            echo "${body}" | jq . >&2 2>/dev/null || echo "${body}" >&2
            fail_count=$((fail_count + 1))
        fi

        # Rate limit protection
        sleep 0.5
    done

    log_info "Phase 3 complete: ${import_count} imported, ${skip_count} skipped (already exist), ${fail_count} failed"
    log_info "You can run phase 4 now"

    if [[ "${fail_count}" -gt 0 ]]; then
        log_error "${fail_count} key(s) failed to import. Do NOT proceed."
        log_error "Fix the errors and re-run phase3 for the failed keys."
    fi
}

# --- Phase 4: Verify keys in KP ---

phase4_verify() {
    log_info "Phase 4: Verifying keys in Key Protect"

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

    local token
    token=$(get_iam_token "${KP_IAM_API_KEY}")
    verify_iam_token "${token}" "${KP_INSTANCE_ID}" "${KP_URL}" "Key Protect"

    local pass_count=0 fail_count=0

    for key_file in "${EXPORTED_DIR}"/*.json; do
        [[ ! -f "${key_file}" ]] && continue

        local key_name original_payload
        key_name=$(jq -r '.name' "${key_file}")
        original_payload=$(jq -r '.payload' "${key_file}")

        # Retrieve by alias — exactly how Rook fetches keys
        local response fetched_payload
        response=$(curl -s \
            -H "authorization: Bearer ${token}" \
            -H "bluemix-instance: ${KP_INSTANCE_ID}" \
            -H "accept: application/vnd.ibm.kms.key+json" \
            "${KP_URL}/api/v2/keys/${key_name}")

        fetched_payload=$(echo "${response}" | jq -r '.resources[0].payload // empty')

        if [[ "${fetched_payload}" == "${original_payload}" ]]; then
            log_info "PASS: ${key_name}"
            jq --arg pvc "${key_name}" \
                '.[$pvc].status = "VERIFIED"' \
                "${DATA_FILE}" >"${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "${DATA_FILE}"
            pass_count=$((pass_count + 1))
        else
            log_error "FAIL: ${key_name} — payload mismatch!"
            log_error "  Original: ${original_payload:0:20}..."
            log_error "  Fetched:  ${fetched_payload:0:20}..."
            fail_count=$((fail_count + 1))
        fi
    done

    if [[ "${fail_count}" -gt 0 ]]; then
        log_error "VERIFICATION FAILED: ${fail_count} key(s) have mismatched payloads."
        log_error "Do NOT proceed. Re-export and re-import the failed keys."
    else
        log_info "ALL ${pass_count} KEYS VERIFIED SUCCESSFULLY. Safe to proceed to phase5."
    fi
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

    # Check all keys are verified
    local unverified
    unverified=$(jq '[.[] | select(.status != "VERIFIED" and .status != "IMPORTED")] | length' "${DATA_FILE}")
    if [[ "${unverified}" -gt 0 ]]; then
        log_warn "${unverified} key(s) are not verified/imported. Consider running phase4 first."
    fi

    log_warn "This will:"
    log_warn "  1. Update the token secret (${TOKEN_SECRET_NAME}) with KP API key"
    log_warn "  2. Update the KMS ConfigMap (${KMS_CONFIGMAP_NAME}) with KP instance ID and URL"
    log_warn "  3. Restart ocs-operator to reconcile ConfigMap -> CephCluster CR"
    log_warn "  4. Rook operator picks up CephCluster CR change -> OSD rolling restart"

    read -rp "Proceed? (yes/no): " confirm
    if [[ "${confirm}" != "yes" ]]; then
        log_info "Phase 5 aborted by user."
        return 1
    fi

    # Step 1: Update token secret (new API key ready for when OSD pods restart)
    log_info "Updating token secret ${TOKEN_SECRET_NAME}..."
    $(kube_cmd) -n "${NS}" create secret generic "${TOKEN_SECRET_NAME}" \
        --from-literal=IBM_KP_SERVICE_API_KEY="${KP_IAM_API_KEY}" \
        --dry-run=client -o yaml |
        $(kube_cmd) apply -f -

    # Verify
    local stored_key
    stored_key=$($(kube_cmd) -n "${NS}" get secret "${TOKEN_SECRET_NAME}" \
        -o jsonpath='{.data.IBM_KP_SERVICE_API_KEY}' | base64 -d)
    if [[ "${stored_key}" != "${KP_IAM_API_KEY}" ]]; then
        log_fatal "Token secret update verification failed!"
    fi
    log_info "Token secret updated and verified."

    # Step 2: Update KMS ConfigMap (source of truth for OCS operator)
    log_info "Updating KMS ConfigMap ${KMS_CONFIGMAP_NAME}..."
    $(kube_cmd) -n "${NS}" patch configmap "${KMS_CONFIGMAP_NAME}" --type merge \
        -p "$(jq -n \
            --arg iid "${KP_INSTANCE_ID}" \
            --arg url "${KP_URL}" \
            '{data: {IBM_KP_SERVICE_INSTANCE_ID: $iid, IBM_KP_BASE_URL: $url}}')"

    # Verify ConfigMap
    local cm_iid
    cm_iid=$($(kube_cmd) -n "${NS}" get configmap "${KMS_CONFIGMAP_NAME}" \
        -o jsonpath='{.data.IBM_KP_SERVICE_INSTANCE_ID}')
    if [[ "${cm_iid}" != "${KP_INSTANCE_ID}" ]]; then
        log_fatal "ConfigMap update verification failed!"
    fi
    log_info "KMS ConfigMap updated and verified."

    # Step 3: Restart ocs-operator to reconcile ConfigMap -> CephCluster CR
    log_info "Restarting ocs-operator..."
    $(kube_cmd) -n "${NS}" rollout restart deploy/ocs-operator
    $(kube_cmd) -n "${NS}" rollout status deploy/ocs-operator --timeout=120s
    log_info "ocs-operator restarted."

    # Step 4: Wait for CephCluster CR to be updated by ocs-operator
    log_info "Waiting for CephCluster CR to be reconciled..."
    local attempts=0 max_attempts=30
    while [[ ${attempts} -lt ${max_attempts} ]]; do
        local updated_id
        updated_id=$($(kube_cmd) -n "${NS}" get cephcluster "${CEPH_CLUSTER_NAME}" \
            -o jsonpath='{.spec.security.kms.connectionDetails.IBM_KP_SERVICE_INSTANCE_ID}' 2>/dev/null || true)
        if [[ "${updated_id}" == "${KP_INSTANCE_ID}" ]]; then
            log_info "CephCluster CR reconciled. Instance ID: ${updated_id}"
            break
        fi
        attempts=$((attempts + 1))
        log_debug "Waiting for CephCluster CR reconciliation (attempt ${attempts}/${max_attempts})..."
        sleep 2
    done

    if [[ ${attempts} -ge ${max_attempts} ]]; then
        log_fatal "CephCluster CR was not reconciled within ${max_attempts} attempts. Check ocs-operator logs."
    fi

    log_info "Phase 5 complete. OSD rolling restart may take a few minutes."
    log_info "Monitor with:"
    log_info "  $(kube_cmd) -n ${NS} get pods -l app=rook-ceph-osd -w"
    log_info "If OSDs do not restart after a few minutes, you can force it with:"
    log_info "  $(kube_cmd) -n ${NS} delete pods -l app=rook-ceph-osd"
    log_info "Run phase 6 to verify recovery once the OSD pods are stable."
}

# --- Phase 6: Verify OSD recovery ---

phase6_verify_recovery() {
    log_info "Phase 6: Verifying OSD recovery"

    log_info "Checking OSD pod status..."
    $(kube_cmd) -n "${NS}" get pods -l app=rook-ceph-osd --no-headers 2>/dev/null |
        while IFS= read -r line; do log_info "  ${line}"; done

    # Check for stuck init containers
    local stuck_pods
    stuck_pods=$($(kube_cmd) -n "${NS}" get pods -l app=rook-ceph-osd \
        --no-headers 2>/dev/null | grep -i init || true)
    if [[ -n "${stuck_pods}" ]]; then
        log_warn "Some OSD pods are stuck in Init state:"
        echo "${stuck_pods}" | while IFS= read -r line; do log_warn "  ${line}"; done
        log_warn "Check init container logs with:"
        log_warn "  $(kube_cmd) -n ${NS} logs <pod-name> -c <container-name>"
    fi

    # Check Ceph health
    log_info "Ceph cluster status:"
    exec_in_toolbox "ceph status" 2>&1 | while IFS= read -r line; do log_info "  ${line}"; done

    log_info "OSD tree:"
    exec_in_toolbox "ceph osd tree" 2>&1 | while IFS= read -r line; do log_info "  ${line}"; done

    log_info "PG status:"
    exec_in_toolbox "ceph pg stat" 2>&1 | while IFS= read -r line; do log_info "  ${line}"; done

    # Check operator logs for errors
    local error_lines
    error_lines=$($(kube_cmd) -n "${NS}" logs deploy/rook-ceph-operator --tail=50 2>/dev/null | grep ' E |' || true)
    if [[ -n "${error_lines}" ]]; then
        log_warn "Recent operator errors:"
        echo "${error_lines}" | while IFS= read -r line; do log_warn "  ${line}"; done
    else
        log_info "No recent operator errors."
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

    log_warn "This will revert the cluster to use HPCS."
    read -rp "Proceed with rollback? (yes/no): " confirm
    if [[ "${confirm}" != "yes" ]]; then
        log_info "Rollback aborted by user."
        return 1
    fi

    # Revert token secret
    log_info "Reverting token secret to HPCS API key..."
    $(kube_cmd) -n "${NS}" create secret generic "${TOKEN_SECRET_NAME}" \
        --from-literal=IBM_KP_SERVICE_API_KEY="${HPCS_IAM_API_KEY}" \
        --dry-run=client -o yaml |
        $(kube_cmd) apply -f -

    # Revert KMS ConfigMap
    log_info "Reverting KMS ConfigMap to HPCS..."
    $(kube_cmd) -n "${NS}" patch configmap "${KMS_CONFIGMAP_NAME}" --type merge \
        -p "$(jq -n \
            --arg iid "${HPCS_INSTANCE_ID}" \
            --arg url "${HPCS_URL}" \
            '{data: {IBM_KP_SERVICE_INSTANCE_ID: $iid, IBM_KP_BASE_URL: $url}}')"

    # Restart ocs-operator to reconcile ConfigMap -> CephCluster CR
    log_info "Restarting ocs-operator..."
    $(kube_cmd) -n "${NS}" rollout restart deploy/ocs-operator
    $(kube_cmd) -n "${NS}" rollout status deploy/ocs-operator --timeout=120s
    log_info "ocs-operator restarted."

    # Wait for CephCluster CR to be reverted by ocs-operator
    log_info "Waiting for CephCluster CR to be reconciled..."
    local attempts=0 max_attempts=30
    while [[ ${attempts} -lt ${max_attempts} ]]; do
        local updated_id
        updated_id=$($(kube_cmd) -n "${NS}" get cephcluster "${CEPH_CLUSTER_NAME}" \
            -o jsonpath='{.spec.security.kms.connectionDetails.IBM_KP_SERVICE_INSTANCE_ID}' 2>/dev/null || true)
        if [[ "${updated_id}" == "${HPCS_INSTANCE_ID}" ]]; then
            log_info "CephCluster CR reconciled. Instance ID: ${updated_id}"
            break
        fi
        attempts=$((attempts + 1))
        log_debug "Waiting for CephCluster CR reconciliation (attempt ${attempts}/${max_attempts})..."
        sleep 2
    done

    if [[ ${attempts} -ge ${max_attempts} ]]; then
        log_fatal "CephCluster CR was not reconciled within ${max_attempts} attempts. Check ocs-operator logs."
    fi

    log_info "Rollback complete. OSD rolling restart may take a few minutes."
    log_info "Monitor with:"
    log_info "  $(kube_cmd) -n ${NS} get pods -l app=rook-ceph-osd -w"
    log_info "If OSDs do not restart after a few minutes, you can force it with:"
    log_info "  $(kube_cmd) -n ${NS} delete pods -l app=rook-ceph-osd"
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

Migrate OSD encryption keys from IBM HPCS to IBM Key Protect.
Rook stores each OSD's DEK as a Standard Key in the KMS, identified by
alias (PVC claim name). This script exports those keys from HPCS and
imports them into Key Protect with the same name, alias, and payload.

Commands:
  check       Check prerequisites and show current KMS config
  phase1      Inventory: list OSD PVCs and match to keys in HPCS
  phase2      Export: download key payloads from HPCS
  phase3      Import: upload keys to Key Protect (same name, alias, payload)
  phase4      Verify: confirm all keys in Key Protect match HPCS
  phase5      Switch: update K8s secret and CephCluster CR to Key Protect (destructive)
  phase6      Verify: check OSD pod recovery and Ceph cluster health
  rollback    Revert K8s resources to HPCS
  cleanup     Delete exported key files (after successful migration)

Environment variables (auto sourced from .env if it exists):
  LOG_LEVEL             Log level: DEBUG, INFO, WARN, ERROR, FATAL (default: INFO)
  DATA_FILE             JSON tracking file (default: osd_keys.json)
  EXPORTED_DIR          Directory for exported key files (default: exported_keys)

  NS                    ODF namespace (default: openshift-storage)
  CEPH_CLUSTER_NAME     CephCluster CR name (default: ocs-storagecluster-cephcluster)
  KMS_CONFIGMAP_NAME    KMS connection details ConfigMap (default: ocs-kms-connection-details)
  TOKEN_SECRET_NAME     Token secret name (auto-detected from CephCluster CR)

  HPCS_INSTANCE_ID      HPCS instance ID (auto-detected from CR if not set)
  HPCS_IAM_API_KEY      HPCS IAM API key (auto-detected from token secret if not set)
  HPCS_URL              HPCS API URL (auto-detected from CR if not set)

  KP_INSTANCE_ID        Key Protect instance ID
  KP_IAM_API_KEY        Key Protect IAM API key
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
