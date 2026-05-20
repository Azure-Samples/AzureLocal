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
#   - An Azure subscription (you'll be prompted to log in via device code)
#
# Usage:
#   chmod +x setup-k3s-arc.sh
#   sudo ./setup-k3s-arc.sh
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

# ── Helper functions ─────────────────────────────────────────────────────────
log()  { echo -e "\n\033[1;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# Run az CLI commands inside a container via K3s's bundled containerd.
# Mounts kubeconfig and a persistent Azure state dir so login survives
# across invocations.
run_az() {
  local container_id="az-cli-$(date +%s%N)"
  k3s ctr run \
    --rm \
    --net-host \
    --mount "type=bind,src=/etc/rancher/k3s/k3s.yaml,dst=/root/.kube/config,options=rbind:ro" \
    --mount "type=bind,src=${AZ_STATE_DIR},dst=/root/.azure,options=rbind:rw" \
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

  # Set up kubeconfig so kubectl and az CLI can find it
  export KUBECONFIG="$k3s_kubeconfig"

  # Also make it accessible for non-root usage later
  local user_home="${SUDO_USER:+$(eval echo ~${SUDO_USER})}"
  if [[ -n "$user_home" ]]; then
    mkdir -p "$user_home/.kube"
    cp "$k3s_kubeconfig" "$user_home/.kube/config"
    chown "$(id -u "${SUDO_USER}")":"$(id -g "${SUDO_USER}")" "$user_home/.kube/config"
    chmod 600 "$user_home/.kube/config"
    log "Kubeconfig copied to $user_home/.kube/config"
  fi

  # Verify connectivity
  kubectl get nodes || err "Cannot reach the Kubernetes API server."
  log "Local kube API server access confirmed."
}

# ── Step 3: Pull Azure CLI container image + install extension + login ────────
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
  # The extension is stored in ~/.azure so it persists across runs
  log "Installing connectedk8s extension..."
  run_az extension add --name connectedk8s --yes 2>/dev/null || \
    run_az extension update --name connectedk8s --yes 2>/dev/null || true

  # Log in to Azure via device code (no browser on the device)
  if ! run_az account show &>/dev/null; then
    log "Please log in to Azure using a device code..."
    run_az_interactive login --use-device-code
  else
    log "Already logged in to Azure."
  fi

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

  # Check if already connected
  if run_az connectedk8s show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" &>/dev/null 2>&1; then
    warn "Cluster '$CLUSTER_NAME' is already connected to Azure Arc. Skipping."
    return
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
    # Append the webhook configuration to the K3s config
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
  echo "============================================================"
  echo "  K3s + Azure Arc Connected Cluster Setup"
  echo "============================================================"
  echo ""
  echo "  Resource Group : $RESOURCE_GROUP"
  echo "  Cluster Name   : $CLUSTER_NAME"
  echo "  Location       : $LOCATION"
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