#!/bin/bash
set -euo pipefail

###############################################################################
# K3s Install + Azure Arc Connected Cluster Setup Script
#
# This script:
#   1. Installs K3s on the local device
#   2. Configures kubeconfig for local API server access
#   3. Pulls the Azure CLI container image (no host install required)
#   4. Connects the K3s cluster to Azure Arc (az connectedk8s connect)
#   5. Enables Azure RBAC on the Arc-enabled cluster
#   6. Configures the K3s API server webhooks for Azure RBAC
#
# The Azure CLI runs entirely inside a container using K3s's bundled
# containerd runtime — nothing is installed on the host OS.
#
# Prerequisites:
#   - Linux device with root/sudo access
#   - Internet connectivity
#   - An Azure subscription with a managed identity assigned to this device
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
#   Then pass the principal ID to this script via --mi-object-id "$principalId"
#
# Usage:
#   chmod +x setup-k3s-arc.sh
#   sudo ./setup-k3s-arc.sh [options]
#
# Or override defaults with environment variables:
#   RESOURCE_GROUP=myRG CLUSTER_NAME=myCluster LOCATION=eastus sudo -E ./setup-k3s-arc.sh
###############################################################################

# ── Configurable variables (override via environment) ────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-arc-k3s-rg}"
CLUSTER_NAME="${CLUSTER_NAME:-arc-k3s-cluster}"
LOCATION="${LOCATION:-eastus}"
K3S_VERSION="${K3S_VERSION:-}"            # leave empty for latest stable
ONBOARDING_TIMEOUT="${ONBOARDING_TIMEOUT:-1200}"
AZ_CLI_IMAGE="${AZ_CLI_IMAGE:-mcr.microsoft.com/azure-cli:latest}"
AZ_STATE_DIR="/tmp/az-cli-state"          # persists Azure login state between runs

AZ_AUTH_MODE="${AZ_AUTH_MODE:-auto}"      # auto | managed-identity | device-code
AZ_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID:-}"
AZ_TENANT_ID="${AZ_TENANT_ID:-}"
AZ_MI_CLIENT_ID="${AZ_MI_CLIENT_ID:-}"
AZ_MI_OBJECT_ID="${AZ_MI_OBJECT_ID:-}"
AZ_MI_RESOURCE_ID="${AZ_MI_RESOURCE_ID:-}"
CUSTOM_LOCATIONS_OID="${CUSTOM_LOCATIONS_OID:-}"

# ── Helper functions ─────────────────────────────────────────────────────────
log()  { echo -e "\n\033[1;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./setup-k3s-arc.sh [options]

Options:
  -g, --resource-group <name>      Azure resource group for connected cluster
  -n, --cluster-name <name>        Arc connected cluster name
  -l, --location <region>          Azure region
      --subscription-id <id>       Azure subscription ID
      --tenant-id <id>             Azure tenant ID
      --auth-mode <mode>           auto | managed-identity | device-code
      --mi-client-id <id>          User-assigned managed identity client ID
      --mi-object-id <id>          User-assigned managed identity object ID
      --mi-resource-id <id>        User-assigned managed identity resource ID
      --custom-locations-oid <id>  Custom Locations service principal object ID
      --onboarding-timeout <secs>  Timeout for az connectedk8s connect
  -h, --help                       Show this help

Examples:
  sudo ./setup-k3s-arc.sh \
    --resource-group rg-sff-se100 \
    --cluster-name se100-edge-ai \
    --location eastus \
    --auth-mode managed-identity \
    --subscription-id <sub-id>
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -g|--resource-group)      RESOURCE_GROUP="$2";      shift 2 ;;
      -n|--cluster-name)        CLUSTER_NAME="$2";         shift 2 ;;
      -l|--location)            LOCATION="$2";             shift 2 ;;
      --subscription-id)        AZ_SUBSCRIPTION_ID="$2";  shift 2 ;;
      --tenant-id)              AZ_TENANT_ID="$2";         shift 2 ;;
      --auth-mode)              AZ_AUTH_MODE="$2";         shift 2 ;;
      --mi-client-id)           AZ_MI_CLIENT_ID="$2";      shift 2 ;;
      --mi-object-id)           AZ_MI_OBJECT_ID="$2";      shift 2 ;;
      --mi-resource-id)         AZ_MI_RESOURCE_ID="$2";    shift 2 ;;
      --custom-locations-oid)   CUSTOM_LOCATIONS_OID="$2"; shift 2 ;;
      --onboarding-timeout)     ONBOARDING_TIMEOUT="$2";   shift 2 ;;
      -h|--help)                usage; exit 0 ;;
      *)                        err "Unknown option: $1" ;;
    esac
  done
}

# Run az CLI commands inside a container via K3s's bundled containerd.
# Mounts kubeconfig, a persistent Azure state dir, and the Arc agent socket
# so managed identity login works via the local IMDS endpoint.
run_az() {
  local container_id="az-cli-$(date +%s%N)"
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

# Interactive variant for commands that need TTY (e.g., device-code login)
run_az_interactive() {
  local container_id="az-cli-$(date +%s%N)"
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

check_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
  fi
}

# ── Step 1: Install K3s ─────────────────────────────────────────────────────
install_k3s() {
  log "Step 1/6 — Installing K3s..."

  if command -v k3s &>/dev/null; then
    warn "K3s is already installed ($(k3s --version)). Skipping install."
  else
    local install_env="INSTALL_K3S_SKIP_SELINUX_RPM=true"
    if [[ -n "${K3S_VERSION}" ]]; then
      install_env="$install_env INSTALL_K3S_VERSION=${K3S_VERSION}"
    fi
    curl -sfL https://get.k3s.io | env $install_env sh -s - --disable traefik
    log "K3s installed successfully."
  fi

  # Wait for the K3s node to be Ready
  log "Waiting for K3s node to become Ready..."
  local retries=30
  while (( retries > 0 )); do
    if k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
      log "K3s node is Ready."
      break
    fi
    retries=$((retries - 1))
    sleep 5
  done
  if (( retries == 0 )); then
    err "Timed out waiting for K3s node to become Ready."
  fi
}

# ── Step 2: Configure kubeconfig for local API access ────────────────────────
configure_kubeconfig() {
  log "Step 2/6 — Configuring kubeconfig for local kube API server access..."

  local k3s_kubeconfig="/etc/rancher/k3s/k3s.yaml"
  if [[ ! -f "$k3s_kubeconfig" ]]; then
    err "K3s kubeconfig not found at $k3s_kubeconfig"
  fi

  export KUBECONFIG="$k3s_kubeconfig"

  local user_home="${SUDO_USER:+$(eval echo ~${SUDO_USER})}"
  if [[ -n "$user_home" ]]; then
    mkdir -p "$user_home/.kube"
    cp "$k3s_kubeconfig" "$user_home/.kube/config"
    chown "$(id -u "${SUDO_USER}")":"$(id -g "${SUDO_USER}")" "$user_home/.kube/config"
    chmod 600 "$user_home/.kube/config"
    log "Kubeconfig copied to $user_home/.kube/config"
  fi

  kubectl get nodes || err "Cannot reach the Kubernetes API server."
  log "Local kube API server access confirmed."
}

# ── Step 3: Pull Azure CLI container image + authenticate + setup ─────────────
authenticate_azure() {
  local -a mi_args=()
  local mi_selector_count=0

  [[ -n "${AZ_MI_CLIENT_ID}" ]]   && { mi_args+=(--client-id "${AZ_MI_CLIENT_ID}");     (( mi_selector_count++ )); }
  [[ -n "${AZ_MI_OBJECT_ID}" ]]   && { mi_args+=(--object-id "${AZ_MI_OBJECT_ID}");     (( mi_selector_count++ )); }
  [[ -n "${AZ_MI_RESOURCE_ID}" ]] && { mi_args+=(--resource-id "${AZ_MI_RESOURCE_ID}"); (( mi_selector_count++ )); }

  if (( mi_selector_count > 1 )); then
    err "Set only one of --mi-client-id, --mi-object-id, --mi-resource-id."
  fi

  local -a tenant_args=()
  [[ -n "${AZ_TENANT_ID}" ]] && tenant_args+=(--tenant "${AZ_TENANT_ID}")

  case "${AZ_AUTH_MODE}" in
    managed-identity|mi)
      log "Authenticating with managed identity..."
      run_az login --identity "${mi_args[@]}" "${tenant_args[@]}" -o none
      ;;
    device-code)
      log "Please log in to Azure using a device code..."
      run_az_interactive login --use-device-code "${tenant_args[@]}"
      ;;
    auto)
      if run_az account show &>/dev/null; then
        log "Already logged in to Azure."
      elif run_az login --identity "${mi_args[@]}" "${tenant_args[@]}" -o none; then
        log "Managed identity login succeeded."
      else
        warn "Managed identity unavailable. Falling back to device code."
        run_az_interactive login --use-device-code "${tenant_args[@]}"
      fi
      ;;
    *)
      err "Invalid --auth-mode: ${AZ_AUTH_MODE}. Use auto, managed-identity, or device-code."
      ;;
  esac

  if [[ -n "${AZ_SUBSCRIPTION_ID}" ]]; then
    log "Setting subscription to ${AZ_SUBSCRIPTION_ID}..."
    run_az account set --subscription "${AZ_SUBSCRIPTION_ID}"
  fi

  run_az account show --query "{name:name,id:id,tenantId:tenantId,user:user.name}" -o table
}

setup_azure_cli() {
  log "Step 3/6 — Setting up Azure CLI container and connectedk8s extension..."

  # Create persistent state dir for Azure login tokens
  mkdir -p "$AZ_STATE_DIR"

  # Pull the Azure CLI image into K3s's containerd
  log "Pulling Azure CLI container image: ${AZ_CLI_IMAGE}..."
  k3s ctr images pull "${AZ_CLI_IMAGE}"

  log "Azure CLI container image ready."
  run_az version --query '"azure-cli"' -o tsv && \
    log "Azure CLI version confirmed." || err "Failed to run az CLI from container."

  # Install the connectedk8s extension inside a persistent state dir
  log "Installing connectedk8s extension..."
  run_az extension add --name connectedk8s --yes 2>/dev/null || \
    run_az extension update --name connectedk8s --yes 2>/dev/null || true

  authenticate_azure

  # Ensure the resource group exists
  if ! run_az group show --name "$RESOURCE_GROUP" &>/dev/null 2>&1; then
    log "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
    run_az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none
  else
    log "Resource group '$RESOURCE_GROUP' already exists."
  fi
}

# ── Step 4: Connect the cluster to Azure Arc ─────────────────────────────────
connect_to_arc() {
  log "Step 4/6 — Connecting K3s cluster to Azure Arc..."

  local existing_cluster
  existing_cluster="$(run_az connectedk8s list \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?name=='${CLUSTER_NAME}'].name | [0]" \
    -o tsv)"

  if [[ -n "$existing_cluster" ]]; then
    warn "Cluster '$CLUSTER_NAME' already connected to Azure Arc."
    warn "Re-running onboarding to ensure azure-arc agents are installed."
  fi

  run_az connectedk8s connect \
    --name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --distribution k3s \
    --infrastructure generic \
    --kube-config /root/.kube/config \
    --onboarding-timeout "$ONBOARDING_TIMEOUT"

  log "Cluster successfully connected to Azure Arc."

  # Verify the connection
  run_az connectedk8s show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o table
}

# ── Step 5: Enable Azure RBAC on the cluster ─────────────────────────────────
enable_azure_rbac() {
  log "Step 5/6 — Enabling Azure RBAC on the Arc-enabled cluster..."

  # Resolve Custom Locations service principal OID (needed for custom-locations feature)
  local custom_locations_oid="${CUSTOM_LOCATIONS_OID}"
  if [[ -z "$custom_locations_oid" ]]; then
    custom_locations_oid="$(run_az ad sp show \
      --id bc313c14-388c-4e7d-a58e-70017303ee3b \
      --query id -o tsv 2>/dev/null || true)"
  fi
  if [[ -z "$custom_locations_oid" ]]; then
    err "Could not resolve Custom Locations OID. Pass --custom-locations-oid or set CUSTOM_LOCATIONS_OID."
  fi

  # Enable cluster-connect and custom-locations features
  log "Enabling Arc features: cluster-connect, custom-locations..."
  run_az connectedk8s enable-features \
    -n "$CLUSTER_NAME" \
    -g "$RESOURCE_GROUP" \
    --features cluster-connect custom-locations \
    --custom-locations-oid "$custom_locations_oid" \
    --kube-config /root/.kube/config

  # Get the cluster's managed identity principal ID
  local cluster_msi_id
  cluster_msi_id=$(run_az connectedk8s show \
    -g "$RESOURCE_GROUP" \
    -n "$CLUSTER_NAME" \
    --query identity.principalId -o tsv)

  if [[ -z "$cluster_msi_id" ]]; then
    err "Could not retrieve the cluster managed identity principal ID."
  fi
  log "Cluster MSI Principal ID: $cluster_msi_id"

  # Get the cluster ARM resource ID
  local cluster_arm_id
  cluster_arm_id=$(run_az connectedk8s show \
    -g "$RESOURCE_GROUP" \
    -n "$CLUSTER_NAME" \
    --query id -o tsv)

  # Assign the Connected Cluster Managed Identity CheckAccess Reader role
  log "Assigning 'Connected Cluster Managed Identity CheckAccess Reader' role..."
  run_az role assignment create \
    --role "Connected Cluster Managed Identity CheckAccess Reader" \
    --assignee "$cluster_msi_id" \
    --scope "$cluster_arm_id" \
    -o none 2>/dev/null || warn "Role assignment may already exist."

  # Enable Azure RBAC feature
  log "Enabling azure-rbac feature on the connected cluster..."
  run_az connectedk8s enable-features \
    -n "$CLUSTER_NAME" \
    -g "$RESOURCE_GROUP" \
    --features azure-rbac \
    --kube-config /root/.kube/config

  log "Azure RBAC enabled on the cluster."
}

# ── Step 6: Configure K3s API server for Azure RBAC webhooks ─────────────────
configure_rbac_webhooks() {
  log "Step 6/6 — Configuring K3s API server for Azure RBAC webhooks..."

  # Extract the guard webhook configs from the Kubernetes secret
  sudo mkdir -p /etc/guard

  kubectl get secrets azure-arc-guard-manifests -n kube-system -o json \
    | jq -r '.data."guard-authn-webhook.yaml"' | base64 -d > /etc/guard/guard-authn-webhook.yaml

  kubectl get secrets azure-arc-guard-manifests -n kube-system -o json \
    | jq -r '.data."guard-authz-webhook.yaml"' | base64 -d > /etc/guard/guard-authz-webhook.yaml

  log "Guard webhook configs written to /etc/guard/"

  # For K3s, configure the API server via the K3s config file
  local k3s_config="/etc/rancher/k3s/config.yaml"

  # Back up existing config if present
  if [[ -f "$k3s_config" ]]; then
    cp "$k3s_config" "${k3s_config}.bak.$(date +%s)"
    log "Backed up existing K3s config."
  fi

  # Check if kube-apiserver-arg already exists in the config
  if [[ -f "$k3s_config" ]] && grep -q 'kube-apiserver-arg' "$k3s_config"; then
    warn "kube-apiserver-arg entries already exist in $k3s_config."
    warn "Please manually verify the following args are present:"
    cat <<'ARGS'
  - authentication-token-webhook-config-file=/etc/guard/guard-authn-webhook.yaml
  - authentication-token-webhook-cache-ttl=5m0s
  - authentication-token-webhook-version=v1
  - authorization-webhook-config-file=/etc/guard/guard-authz-webhook.yaml
  - authorization-webhook-cache-authorized-ttl=5m0s
  - authorization-webhook-version=v1
  - authorization-mode=Node,RBAC,Webhook
ARGS
  else
    cat >> "$k3s_config" <<'EOF'

# Azure Arc RBAC webhook configuration
kube-apiserver-arg:
  - "authentication-token-webhook-config-file=/etc/guard/guard-authn-webhook.yaml"
  - "authentication-token-webhook-cache-ttl=5m0s"
  - "authentication-token-webhook-version=v1"
  - "authorization-webhook-config-file=/etc/guard/guard-authz-webhook.yaml"
  - "authorization-webhook-cache-authorized-ttl=5m0s"
  - "authorization-webhook-version=v1"
  - "authorization-mode=Node,RBAC,Webhook"
EOF
    log "K3s API server webhook args written to $k3s_config"
  fi

  # Restart K3s to apply the new API server configuration
  log "Restarting K3s to apply webhook configuration..."
  systemctl restart k3s

  # Wait for K3s to come back up
  log "Waiting for K3s to restart..."
  local retries=30
  while (( retries > 0 )); do
    if kubectl get nodes &>/dev/null 2>&1; then
      log "K3s is back up and running."
      break
    fi
    retries=$((retries - 1))
    sleep 5
  done
  if (( retries == 0 )); then
    err "Timed out waiting for K3s to restart after webhook configuration."
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  echo "============================================================"
  echo "  K3s + Azure Arc Connected Cluster Setup"
  echo "============================================================"
  echo ""
  echo "  Resource Group : $RESOURCE_GROUP"
  echo "  Cluster Name   : $CLUSTER_NAME"
  echo "  Location       : $LOCATION"
  echo "  Auth Mode      : $AZ_AUTH_MODE"
  echo ""

  check_root
  install_k3s
  configure_kubeconfig
  setup_azure_cli
  connect_to_arc
  enable_azure_rbac
  configure_rbac_webhooks

  echo ""
  log "============================================================"
  log "  Setup complete!"
  log "  Cluster '$CLUSTER_NAME' is connected to Azure Arc with"
  log "  Azure RBAC enabled."
  log ""
  log "  Verify with:"
  log "    run_az connectedk8s show -g $RESOURCE_GROUP -n $CLUSTER_NAME -o table"
  log "    kubectl get pods -n azure-arc"
  log "============================================================"
}

main "$@"
