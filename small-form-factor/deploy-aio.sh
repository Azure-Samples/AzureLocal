#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Deploy Azure IoT Operations to an Arc-enabled K3s cluster.
#
# Auth modes:
#   - auto (default): existing session -> managed identity -> device code
#   - managed-identity: managed identity only
#   - device-code: device code only
#
# Managed Identity Setup (run once from a workstation before this script):
#
#   1. Enable system-assigned managed identity on the Arc-connected machine:
#        az connectedmachine update \
#          --resource-group <resource-group> \
#          --name <arc-machine-name> \
#          --set identity.type="SystemAssigned"
#
#   2. Retrieve the managed identity principal ID:
#        az connectedmachine show \
#          --resource-group <resource-group> \
#          --name <arc-machine-name> \
#          --query identity
#
#        principalId=$(az connectedmachine show \
#          --resource-group <resource-group> \
#          --name <arc-machine-name> \
#          --query identity.principalId -o tsv)
#
#   3. Assign Contributor on the subscription (for Arc onboarding):
#        az role assignment create \
#          --assignee "$principalId" \
#          --role Contributor \
#          --scope "/subscriptions/<subscription-id>"
#
#   4. Assign Storage Blob Data Contributor on the resource group
#      (required for AIO schema registry and storage):
#        az role assignment create \
#          --assignee-object-id "$principalId" \
#          --assignee-principal-type ServicePrincipal \
#          --role "Storage Blob Data Contributor" \
#          --scope "/subscriptions/<subscription-id>/resourceGroups/<resource-group>"
#
#   5. Assign User Access Administrator on the resource group
#      (required for AIO to manage RBAC on its own resources):
#        az role assignment create \
#          --assignee-object-id "$principalId" \
#          --assignee-principal-type ServicePrincipal \
#          --role "User Access Administrator" \
#          --scope "/subscriptions/<subscription-id>/resourceGroups/<resource-group>"
#
#   6. Assign Contributor on the resource group:
#        az role assignment create \
#          --assignee-object-id "$principalId" \
#          --assignee-principal-type ServicePrincipal \
#          --role "Contributor" \
#          --scope "/subscriptions/<subscription-id>/resourceGroups/<resource-group>"
#
#   7. Get the Custom Locations OID (service principal for the custom-locations
#      feature — this is a fixed Microsoft app ID):
#        customLocationsOid=$(az ad sp show \
#          --id bc313c14-388c-4e7d-a58e-70017303ee3b \
#          --query id -o tsv)
#
#   8. Enable cluster-connect and custom-locations on the Arc cluster:
#        az connectedk8s enable-features \
#          --name <cluster-name> \
#          --resource-group <resource-group> \
#          --features cluster-connect custom-locations \
#          --custom-locations-oid "$customLocationsOid"
#
###############################################################################

RESOURCE_GROUP="${RESOURCE_GROUP:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
LOCATION="${LOCATION:-eastus}"
AIO_INSTANCE_NAME="${AIO_INSTANCE_NAME:-}"

SCHEMA_REGISTRY_ID="${SCHEMA_REGISTRY_ID:-}"
SCHEMA_REGISTRY_NAME="${SCHEMA_REGISTRY_NAME:-}"
NS_RESOURCE_ID="${NS_RESOURCE_ID:-}"
NS_NAME="${NS_NAME:-}"
STORAGE_ACCOUNT_ID="${STORAGE_ACCOUNT_ID:-}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-}"
CREATE_STORAGE_ACCOUNT="${CREATE_STORAGE_ACCOUNT:-false}"
STORAGE_ACCOUNT_SKU="${STORAGE_ACCOUNT_SKU:-Standard_LRS}"
STORAGE_ACCOUNT_KIND="${STORAGE_ACCOUNT_KIND:-StorageV2}"
STORAGE_ACCOUNT_HNS="${STORAGE_ACCOUNT_HNS:-true}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-edge-ai-mvp}"

DEPLOY_PROFILE="${DEPLOY_PROFILE:-low}"
AIO_NAMESPACE="${AIO_NAMESPACE:-azure-iot-operations}"

AZ_CLI_IMAGE="${AZ_CLI_IMAGE:-mcr.microsoft.com/azure-cli:latest}"
AZ_STATE_DIR="${AZ_STATE_DIR:-/tmp/az-cli-state}"

AZ_AUTH_MODE="${AZ_AUTH_MODE:-auto}"
AZ_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID:-}"
AZ_TENANT_ID="${AZ_TENANT_ID:-}"
AZ_MI_CLIENT_ID="${AZ_MI_CLIENT_ID:-}"
AZ_MI_OBJECT_ID="${AZ_MI_OBJECT_ID:-}"
AZ_MI_RESOURCE_ID="${AZ_MI_RESOURCE_ID:-}"
AZ_RETRY_MAX_ATTEMPTS="${AZ_RETRY_MAX_ATTEMPTS:-3}"
AZ_RETRY_DELAY_SECONDS="${AZ_RETRY_DELAY_SECONDS:-15}"

log() {
  echo -e "\n\033[1;32m[INFO]\033[0m  $*"
}

warn() {
  echo -e "\n\033[1;33m[WARN]\033[0m  $*"
}

err() {
  echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./deploy-aio.sh [options]

Required:
  -g, --resource-group <name>       Resource group for Arc cluster and AIO
  -n, --cluster-name <name>         Arc connected cluster name

Schema registry input (choose one mode):
  --schema-registry-id <id>         Existing schema registry resource ID
  OR
  --schema-registry-name <name>     Schema registry name to create/use
  --ns-resource-id <id>              Existing device registry namespace ID
  --ns-name <name>                   Device registry namespace name (create/use)
  --storage-account-id <id>         Existing storage account resource ID
  --storage-account-name <name>     Storage account name (existing or to create)
  --create-storage-account          Create storage account if not found
  --storage-account-sku <sku>       Storage account SKU (default: Standard_LRS)
  --storage-account-kind <kind>     Storage account kind (default: StorageV2)
  --storage-account-hns <true|false>
                                    Enable hierarchical namespace (default: true)

Optional:
  -l, --location <region>           Azure region (default: eastus)
  --aio-instance-name <name>        AIO instance name (default: <cluster>-instance)
  --registry-namespace <name>       Schema registry namespace
  --deploy-profile <profile>        low | default (default: low)

Auth options:
  --auth-mode <mode>                auto | managed-identity | device-code
  --subscription-id <id>            Azure subscription ID
  --tenant-id <id>                  Azure tenant ID
  --mi-client-id <id>               User-assigned managed identity client ID
  --mi-object-id <id>               User-assigned managed identity object ID
  --mi-resource-id <id>             User-assigned managed identity resource ID

Other:
  -h, --help                        Show this help

Examples:
  sudo ./deploy-aio.sh \
    --resource-group rg-sff-se100 \
    --cluster-name se100-edge-ai \
    --schema-registry-name sr-se100 \
    --storage-account-name saedge1234 \
    --create-storage-account \
    --auth-mode managed-identity \
    --subscription-id <sub-id>

  sudo ./deploy-aio.sh \
    --resource-group rg-sff-se100 \
    --cluster-name se100-edge-ai \
    --schema-registry-id /subscriptions/.../providers/Microsoft.DeviceRegistry/schemaRegistries/sr-se100 \
    --ns-resource-id /subscriptions/.../providers/Microsoft.DeviceRegistry/namespaces/my-ns \
    --auth-mode auto \
    --subscription-id <sub-id>
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -g|--resource-group)
        RESOURCE_GROUP="$2"
        shift 2
        ;;
      -n|--cluster-name)
        CLUSTER_NAME="$2"
        shift 2
        ;;
      -l|--location)
        LOCATION="$2"
        shift 2
        ;;
      --aio-instance-name)
        AIO_INSTANCE_NAME="$2"
        shift 2
        ;;
      --schema-registry-id)
        SCHEMA_REGISTRY_ID="$2"
        shift 2
        ;;
      --schema-registry-name)
        SCHEMA_REGISTRY_NAME="$2"
        shift 2
        ;;
      --ns-resource-id)
        NS_RESOURCE_ID="$2"
        shift 2
        ;;
      --ns-name)
        NS_NAME="$2"
        shift 2
        ;;
      --storage-account-id)
        STORAGE_ACCOUNT_ID="$2"
        shift 2
        ;;
      --storage-account-name)
        STORAGE_ACCOUNT_NAME="$2"
        shift 2
        ;;
      --create-storage-account)
        CREATE_STORAGE_ACCOUNT="true"
        shift 1
        ;;
      --storage-account-sku)
        STORAGE_ACCOUNT_SKU="$2"
        shift 2
        ;;
      --storage-account-kind)
        STORAGE_ACCOUNT_KIND="$2"
        shift 2
        ;;
      --storage-account-hns)
        STORAGE_ACCOUNT_HNS="$2"
        shift 2
        ;;
      --registry-namespace)
        REGISTRY_NAMESPACE="$2"
        shift 2
        ;;
      --deploy-profile)
        DEPLOY_PROFILE="$2"
        shift 2
        ;;
      --auth-mode)
        AZ_AUTH_MODE="$2"
        shift 2
        ;;
      --subscription-id)
        AZ_SUBSCRIPTION_ID="$2"
        shift 2
        ;;
      --tenant-id)
        AZ_TENANT_ID="$2"
        shift 2
        ;;
      --mi-client-id)
        AZ_MI_CLIENT_ID="$2"
        shift 2
        ;;
      --mi-object-id)
        AZ_MI_OBJECT_ID="$2"
        shift 2
        ;;
      --mi-resource-id)
        AZ_MI_RESOURCE_ID="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown option: $1"
        ;;
    esac
  done
}

check_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
  fi
}

check_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    err "Required command not found: ${cmd}"
  fi
}

validate_inputs() {
  if [[ -z "${RESOURCE_GROUP}" ]]; then
    err "--resource-group is required"
  fi

  if [[ -z "${CLUSTER_NAME}" ]]; then
    err "--cluster-name is required"
  fi

  if [[ -z "${AIO_INSTANCE_NAME}" ]]; then
    AIO_INSTANCE_NAME="${CLUSTER_NAME}-instance"
  fi

  if [[ -z "${NS_RESOURCE_ID}" ]] && [[ -z "${NS_NAME}" ]]; then
    NS_NAME="${CLUSTER_NAME}-ns"
  fi

  if [[ -z "${SCHEMA_REGISTRY_ID}" ]]; then
    if [[ -z "${SCHEMA_REGISTRY_NAME}" ]]; then
      err "Provide --schema-registry-id or --schema-registry-name"
    fi
    if [[ -z "${STORAGE_ACCOUNT_ID}" ]] && [[ -z "${STORAGE_ACCOUNT_NAME}" ]]; then
      err "Provide --storage-account-id or --storage-account-name"
    fi
    if [[ "${CREATE_STORAGE_ACCOUNT}" == "true" ]] && [[ -z "${STORAGE_ACCOUNT_NAME}" ]]; then
      err "--storage-account-name is required with --create-storage-account"
    fi
  fi

  if [[ "${DEPLOY_PROFILE}" != "low" ]] && [[ "${DEPLOY_PROFILE}" != "default" ]]; then
    err "--deploy-profile must be one of: low, default"
  fi

  if [[ "${STORAGE_ACCOUNT_HNS}" != "true" ]] && [[ "${STORAGE_ACCOUNT_HNS}" != "false" ]]; then
    err "--storage-account-hns must be true or false"
  fi
}

configure_kubeconfig() {
  local k3s_kubeconfig
  k3s_kubeconfig="/etc/rancher/k3s/k3s.yaml"

  if [[ ! -f "${k3s_kubeconfig}" ]]; then
    err "K3s kubeconfig not found at ${k3s_kubeconfig}"
  fi

  export KUBECONFIG="${k3s_kubeconfig}"

  local user_home=""
  if [[ -n "${SUDO_USER:-}" ]]; then
    user_home="$(eval echo ~${SUDO_USER})"
    mkdir -p "${user_home}/.kube"
    cp "${k3s_kubeconfig}" "${user_home}/.kube/config"
    chown "$(id -u "${SUDO_USER}")":"$(id -g "${SUDO_USER}")" \
      "${user_home}/.kube/config"
    chmod 600 "${user_home}/.kube/config"
  fi

  kubectl get nodes >/dev/null
}

run_az() {
  local container_id
  container_id="az-cli-$(date +%s%N)"

  k3s ctr run \
    --rm \
    --net-host \
    --mount "type=bind,src=/etc/rancher/k3s/k3s.yaml,dst=/root/.kube/config,options=rbind:ro" \
    --mount "type=bind,src=${AZ_STATE_DIR},dst=/root/.azure,options=rbind:rw" \
    --mount "type=bind,src=/var/opt/azcmagent,dst=/var/opt/azcmagent,options=rbind:ro" \
    --env IMDS_ENDPOINT=http://localhost:40342 \
    --env IDENTITY_ENDPOINT=http://localhost:40342/metadata/identity/oauth2/token \
    "${AZ_CLI_IMAGE}" \
    "${container_id}" \
    az "$@"
}

run_az_interactive() {
  local container_id
  container_id="az-cli-$(date +%s%N)"

  k3s ctr run \
    --rm \
    --tty \
    --net-host \
    --mount "type=bind,src=/etc/rancher/k3s/k3s.yaml,dst=/root/.kube/config,options=rbind:ro" \
    --mount "type=bind,src=${AZ_STATE_DIR},dst=/root/.azure,options=rbind:rw" \
    --mount "type=bind,src=/var/opt/azcmagent,dst=/var/opt/azcmagent,options=rbind:ro" \
    --env IMDS_ENDPOINT=http://localhost:40342 \
    --env IDENTITY_ENDPOINT=http://localhost:40342/metadata/identity/oauth2/token \
    "${AZ_CLI_IMAGE}" \
    "${container_id}" \
    az "$@"
}

is_transient_az_error() {
  local msg="$1"

  if echo "${msg}" | grep -Eq "RemoteDisconnected|Connection aborted|timed out|EOF|Temporary failure|connection reset"; then
    return 0
  fi

  return 1
}

run_az_with_retry() {
  local attempt
  attempt=1

  while true; do
    local output
    if output="$(run_az "$@" 2>&1)"; then
      if [[ -n "${output}" ]]; then
        echo "${output}"
      fi
      return 0
    fi

    if (( attempt >= AZ_RETRY_MAX_ATTEMPTS )) || ! is_transient_az_error "${output}"; then
      echo "${output}" >&2
      return 1
    fi

    warn "Transient Azure CLI error detected (attempt ${attempt}/${AZ_RETRY_MAX_ATTEMPTS})."
    warn "Retrying in ${AZ_RETRY_DELAY_SECONDS}s..."
    attempt=$((attempt + 1))
    sleep "${AZ_RETRY_DELAY_SECONDS}"
  done
}

setup_azure_cli() {
  mkdir -p "${AZ_STATE_DIR}"

  log "Pulling Azure CLI image: ${AZ_CLI_IMAGE}"
  k3s ctr images pull "${AZ_CLI_IMAGE}"

  run_az version --query '"azure-cli"' -o tsv >/dev/null

  log "Installing Azure CLI extensions..."
  if ! run_az extension add --name connectedk8s --yes; then
    run_az extension update --name connectedk8s --yes
  fi

  if ! run_az extension add --name azure-iot-ops --yes; then
    run_az extension update --name azure-iot-ops --yes
  fi

  run_az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
}

authenticate_azure() {
  local -a mi_args=()
  local mi_selector_count=0

  if [[ -n "${AZ_MI_CLIENT_ID}" ]]; then
    mi_args+=(--client-id "${AZ_MI_CLIENT_ID}")
    mi_selector_count=$((mi_selector_count + 1))
  fi

  if [[ -n "${AZ_MI_OBJECT_ID}" ]]; then
    mi_args+=(--object-id "${AZ_MI_OBJECT_ID}")
    mi_selector_count=$((mi_selector_count + 1))
  fi

  if [[ -n "${AZ_MI_RESOURCE_ID}" ]]; then
    mi_args+=(--resource-id "${AZ_MI_RESOURCE_ID}")
    mi_selector_count=$((mi_selector_count + 1))
  fi

  if (( mi_selector_count > 1 )); then
    err "Set only one of AZ_MI_CLIENT_ID, AZ_MI_OBJECT_ID, AZ_MI_RESOURCE_ID"
  fi

  local -a tenant_args=()
  if [[ -n "${AZ_TENANT_ID}" ]]; then
    tenant_args+=(--tenant "${AZ_TENANT_ID}")
  fi

  case "${AZ_AUTH_MODE}" in
    managed-identity|mi)
      log "Authenticating with managed identity..."
      run_az login --identity "${mi_args[@]}" "${tenant_args[@]}" -o none
      ;;
    device-code)
      log "Authenticating with device code..."
      run_az_interactive login --use-device-code "${tenant_args[@]}" -o none
      ;;
    auto)
      if run_az account show -o none; then
        log "Using existing Azure CLI session."
      elif run_az login --identity "${mi_args[@]}" "${tenant_args[@]}" -o none; then
        log "Managed identity login succeeded."
      else
        warn "Managed identity unavailable. Falling back to device code."
        run_az_interactive login --use-device-code "${tenant_args[@]}" -o none
      fi
      ;;
    *)
      err "Invalid --auth-mode: ${AZ_AUTH_MODE}"
      ;;
  esac

  if [[ -n "${AZ_SUBSCRIPTION_ID}" ]]; then
    run_az account set --subscription "${AZ_SUBSCRIPTION_ID}"
  fi

  run_az account show \
    --query "{name:name,id:id,tenantId:tenantId,user:user.name}" \
    -o table
}

ensure_cluster_connected() {
  local cluster_id
  cluster_id="$(run_az connectedk8s list \
    --resource-group "${RESOURCE_GROUP}" \
    --query "[?name=='${CLUSTER_NAME}'].id | [0]" \
    -o tsv)"

  if [[ -z "${cluster_id}" ]]; then
    err "Arc cluster '${CLUSTER_NAME}' not found in '${RESOURCE_GROUP}'."
  fi

  log "Arc cluster found: ${CLUSTER_NAME}"
}

resolve_storage_account_id() {
  if [[ -n "${STORAGE_ACCOUNT_ID}" ]]; then
    log "Using provided storage account ID."
    return
  fi

  local existing_id
  existing_id="$(run_az storage account show \
    --name "${STORAGE_ACCOUNT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query id \
    -o tsv 2>/dev/null || true)"

  if [[ -n "${existing_id}" ]]; then
    STORAGE_ACCOUNT_ID="${existing_id}"
    log "Using existing storage account: ${STORAGE_ACCOUNT_NAME}"
    return
  fi

  if [[ "${CREATE_STORAGE_ACCOUNT}" != "true" ]]; then
    err "Storage account not found. Re-run with --create-storage-account"
  fi

  if [[ "${STORAGE_ACCOUNT_HNS}" == "true" ]]; then
    log "Creating storage account: ${STORAGE_ACCOUNT_NAME} with hierarchical namespace enabled"
  else
    log "Creating storage account: ${STORAGE_ACCOUNT_NAME}"
  fi
  run_az storage account create \
    --name "${STORAGE_ACCOUNT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --sku "${STORAGE_ACCOUNT_SKU}" \
    --kind "${STORAGE_ACCOUNT_KIND}" \
    --enable-hierarchical-namespace "${STORAGE_ACCOUNT_HNS}" \
    --allow-blob-public-access false \
    -o none

  STORAGE_ACCOUNT_ID="$(run_az storage account show \
    --name "${STORAGE_ACCOUNT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query id \
    -o tsv)"

  log "Storage account ready: ${STORAGE_ACCOUNT_ID}"
}

build_unique_registry_namespace() {
  local base
  base="${REGISTRY_NAMESPACE}"
  base="$(echo "${base}" | tr '[:upper:]' '[:lower:]')"
  base="$(echo "${base}" | tr -cd 'a-z0-9-')"
  base="${base#-}"
  base="${base%-}"

  if [[ -z "${base}" ]]; then
    base="edge-ai-mvp"
  fi

  local suffix
  suffix="$(date +%s | tail -c 5)"

  printf "%s-%s" "${base:0:32}" "${suffix}"
}

resolve_schema_registry_id() {
  if [[ -n "${SCHEMA_REGISTRY_ID}" ]]; then
    log "Using existing schema registry ID."
    return
  fi

  local existing_id
  existing_id="$(run_az iot ops schema registry show \
    --name "${SCHEMA_REGISTRY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query id \
    -o tsv 2>/dev/null || true)"

  if [[ -n "${existing_id}" ]]; then
    SCHEMA_REGISTRY_ID="${existing_id}"
    log "Using existing schema registry: ${SCHEMA_REGISTRY_NAME}"
    return
  fi

  log "Creating schema registry: ${SCHEMA_REGISTRY_NAME}"

  local create_output
  create_output=""

  if ! create_output="$(run_az iot ops schema registry create \
    --name "${SCHEMA_REGISTRY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --registry-namespace "${REGISTRY_NAMESPACE}" \
    --sa-resource-id "${STORAGE_ACCOUNT_ID}" 2>&1)"; then
    echo "${create_output}" >&2

    if echo "${create_output}" | grep -q "SchemaRegistryNamespaceAlreadyInUseError";
    then
      REGISTRY_NAMESPACE="$(build_unique_registry_namespace)"
      warn "Schema registry namespace already in use."
      warn "Retrying with namespace: ${REGISTRY_NAMESPACE}"

      run_az iot ops schema registry create \
        --name "${SCHEMA_REGISTRY_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --registry-namespace "${REGISTRY_NAMESPACE}" \
        --sa-resource-id "${STORAGE_ACCOUNT_ID}"
    else
      err "Failed to create schema registry '${SCHEMA_REGISTRY_NAME}'."
    fi
  fi

  SCHEMA_REGISTRY_ID="$(run_az iot ops schema registry show \
    --name "${SCHEMA_REGISTRY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query id \
    -o tsv)"

  log "Schema registry ready: ${SCHEMA_REGISTRY_ID}"
}

resolve_namespace_resource_id() {
  if [[ -n "${NS_RESOURCE_ID}" ]]; then
    log "Using existing namespace resource ID."
    return
  fi

  local existing_id
  existing_id="$(run_az iot ops ns show \
    --name "${NS_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query id \
    -o tsv 2>/dev/null || true)"

  if [[ -n "${existing_id}" ]]; then
    NS_RESOURCE_ID="${existing_id}"
    log "Using existing device registry namespace: ${NS_NAME}"
    return
  fi

  log "Creating device registry namespace: ${NS_NAME}"
  run_az iot ops ns create \
    --name "${NS_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    -o none

  NS_RESOURCE_ID="$(run_az iot ops ns show \
    --name "${NS_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query id \
    -o tsv)"

  log "Namespace ready: ${NS_RESOURCE_ID}"
}

init_aio() {
  log "Initializing Azure IoT Operations components on cluster..."

  run_az_with_retry iot ops init \
    --cluster "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}"
}

deploy_aio() {
  log "Deploying Azure IoT Operations instance: ${AIO_INSTANCE_NAME}"

  if [[ "${DEPLOY_PROFILE}" == "low" ]]; then
    run_az_with_retry iot ops create \
      --cluster "${CLUSTER_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${AIO_INSTANCE_NAME}" \
      --sr-resource-id "${SCHEMA_REGISTRY_ID}" \
      --ns-resource-id "${NS_RESOURCE_ID}" \
      --broker-frontend-replicas 1 \
      --broker-frontend-workers 1 \
      --broker-backend-part 1 \
      --broker-backend-workers 1 \
      --broker-backend-rf 2 \
      --broker-mem-profile Low
  else
    run_az_with_retry iot ops create \
      --cluster "${CLUSTER_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${AIO_INSTANCE_NAME}" \
      --sr-resource-id "${SCHEMA_REGISTRY_ID}" \
      --ns-resource-id "${NS_RESOURCE_ID}"
  fi
}

verify_aio() {
  log "Verifying Azure IoT Operations pods..."

  kubectl get pods -n "${AIO_NAMESPACE}" || true

  local running_count
  running_count="$(kubectl get pods -n "${AIO_NAMESPACE}" --no-headers 2>/dev/null \
    | grep -c "Running" || true)"

  if [[ "${running_count}" == "0" ]]; then
    err "No running pods found in namespace '${AIO_NAMESPACE}'."
  fi

  log "AIO deployment appears healthy in namespace '${AIO_NAMESPACE}'."
}

ensure_aio_namespace() {
  log "Ensuring namespace exists: ${AIO_NAMESPACE}"

  if kubectl get namespace "${AIO_NAMESPACE}" >/dev/null 2>&1; then
    log "Namespace already exists: ${AIO_NAMESPACE}"
    return
  fi

  if ! kubectl create namespace "${AIO_NAMESPACE}" >/dev/null 2>&1; then
    err "Failed to create namespace '${AIO_NAMESPACE}'. Host cluster API may be unhealthy."
  fi

  log "Namespace created: ${AIO_NAMESPACE}"
}

main() {
  parse_args "$@"
  validate_inputs

  echo "============================================================"
  echo "  Azure IoT Operations Deployment"
  echo "============================================================"
  echo ""
  echo "  Resource Group : ${RESOURCE_GROUP}"
  echo "  Cluster Name   : ${CLUSTER_NAME}"
  echo "  Location       : ${LOCATION}"
  echo "  AIO Instance   : ${AIO_INSTANCE_NAME:-<auto>}"
  echo "  Deploy Profile : ${DEPLOY_PROFILE}"
  echo "  Auth Mode      : ${AZ_AUTH_MODE}"
  echo ""

  check_root
  check_command k3s
  check_command kubectl

  configure_kubeconfig
  setup_azure_cli
  authenticate_azure
  ensure_cluster_connected
  resolve_storage_account_id
  resolve_schema_registry_id
  resolve_namespace_resource_id
  init_aio
  ensure_aio_namespace
  deploy_aio
  verify_aio

  log "Azure IoT Operations deployment complete."
  log "Schema Registry ID: ${SCHEMA_REGISTRY_ID}"
  log "Namespace ID: ${NS_RESOURCE_ID}"
}

main "$@"
