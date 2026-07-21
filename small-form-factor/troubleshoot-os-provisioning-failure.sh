#!/bin/bash
set -e

# Script to retry OS provisioning on an edge machine by resubmitting the ProvisionOS job
# Performs a reput with osProfile and userDetails

# Input parameters
SUBSCRIPTION_ID=<subscription-id> 
RESOURCE_GROUP=<resource-group>
PROVISIONED_MACHINE_NAME=<edge-machine-name>

# Validate inputs
if [ -z "$SUBSCRIPTION_ID" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$PROVISIONED_MACHINE_NAME" ]; then
    echo "Usage: $0 <subscription-id> <resource-group> <edge-machine-name>"
    exit 1
fi

echo "Subscription ID: $SUBSCRIPTION_ID"
echo "Resource Group: $RESOURCE_GROUP"
echo "Edge Machine Name: $PROVISIONED_MACHINE_NAME"

# Set the subscription
echo "Setting subscription..."
az account set --subscription "$SUBSCRIPTION_ID"

# Construct the ProvisionOS job endpoint
PROVISION_OS_URL="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.AzureStackHCI/edgeMachines/$PROVISIONED_MACHINE_NAME/jobs/ProvisionOs"
EDGE_MACHINE_URL="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.AzureStackHCI/edgeMachines/$PROVISIONED_MACHINE_NAME"
API_VERSION="2025-12-01-preview"

echo "Getting edge machine configuration..."
# GET the edge machine to extract userDetails
EDGE_MACHINE_CONFIG=$(az rest \
    --method GET \
    --url "https://management.azure.com${EDGE_MACHINE_URL}?api-version=${API_VERSION}" \
    --output json)

echo "Edge machine configuration retrieved"

# Extract userDetails and osProfile from edge machine
USER_DETAILS=$(echo "$EDGE_MACHINE_CONFIG" | jq '.properties.provisioningDetails.userDetails')
OS_PROFILE=$(echo "$EDGE_MACHINE_CONFIG" | jq '.properties.provisioningDetails.osProfile')
SITE_RESOURCE_ID=$(echo "$EDGE_MACHINE_CONFIG" | jq -r '.properties.siteDetails.siteResourceId')
NETWORK_ID=$(echo "$EDGE_MACHINE_CONFIG" | jq -r '.properties.siteDetails.deviceConfiguration')

if [ "$USER_DETAILS" == "null" ] || [ "$OS_PROFILE" == "null" ]; then
    echo "Error: Could not extract userDetails or osProfile from the edge machine configuration"
    echo "Edge machine config: $EDGE_MACHINE_CONFIG"
    exit 1
fi

# Hardcode target and jobType
TARGET="AzureLinux"
JOB_TYPE="ProvisionOs"

echo "Extracted osProfile and userDetails from edge machine; using hardcoded target: $TARGET and jobType: $JOB_TYPE"

# Create the PUT body with osProfile, userDetails, target, and jobType
PUT_BODY=$(jq -n \
    --argjson osProfile "$OS_PROFILE" \
    --argjson userDetails "$USER_DETAILS" \
    --arg target "$TARGET" \
    --arg jobType "$JOB_TYPE" \
    --argjson networkId "$NETWORK_ID" \
    '{
        properties: {
            jobType: $jobType,
            provisioningRequest: {
                osProfile: $osProfile,
                userDetails: $userDetails,
                target: $target,
                deviceConfiguration: $networkId
            }
        }
    }')

echo "Performing reput to retry OS provisioning..."
# PUT the configuration back to trigger a retry
az rest \
    --method PUT \
    --url "https://management.azure.com${PROVISION_OS_URL}?api-version=${API_VERSION}" \
    --body "$PUT_BODY" \
    --output json

echo "ProvisionOS retry submitted successfully"
