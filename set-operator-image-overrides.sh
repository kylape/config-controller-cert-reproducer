#!/usr/bin/env bash
#
# set-operator-image-overrides.sh
# Sets RELATED_IMAGE_* environment variables on the operator deployment
# to override container images used by Central
#
# Usage: ./set-operator-image-overrides.sh [WORKTREE_DIR]
#   If WORKTREE_DIR is not provided, uses /root/workspace/src/stackrox
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIND_TAG_SCRIPT="${SCRIPT_DIR}/find-good-quay-tag.sh"

# Allow WORKTREE_DIR to be passed as argument or use default
WORKTREE_DIR="${1:-${WORKTREE_DIR:-/root/workspace/src/stackrox}}"

# Operator deployment details
OPERATOR_NAMESPACE="rhacs-operator-system"
OPERATOR_DEPLOYMENT="rhacs-operator-controller-manager"

# Image registry base
IMAGE_REGISTRY="quay.io/stackrox-io"

echo "======================================"
echo "Set Operator Image Overrides"
echo "======================================"
echo ""

# Check if operator deployment exists
if ! kubectl get deployment -n "$OPERATOR_NAMESPACE" "$OPERATOR_DEPLOYMENT" >/dev/null 2>&1; then
    echo "❌ ERROR: Operator deployment not found!"
    echo "   Namespace: $OPERATOR_NAMESPACE"
    echo "   Deployment: $OPERATOR_DEPLOYMENT"
    exit 1
fi

# Check if QUAY_TAG is already set
if [ -z "${QUAY_TAG:-}" ]; then
    echo "Finding good image tag from origin/master..."
    echo ""

    # Check if find-good-quay-tag.sh script exists
    if [ ! -f "$FIND_TAG_SCRIPT" ]; then
        echo "❌ ERROR: QUAY_TAG not set and find-good-quay-tag.sh not found!"
        echo ""
        echo "Please set QUAY_TAG environment variable with a valid image tag:"
        echo "  export QUAY_TAG=4.10.x-415-gd1af0f418d"
        echo "  $0"
        exit 1
    fi

    # Run the find-good-quay-tag script and capture output
    TAG_OUTPUT=$("${FIND_TAG_SCRIPT}" "$WORKTREE_DIR")
    TAG_EXIT_CODE=$?

    if [ $TAG_EXIT_CODE -ne 0 ]; then
        echo "❌ ERROR: Failed to find good image tag!"
        echo "$TAG_OUTPUT"
        exit 1
    fi

    # Extract QUAY_TAG from output
    QUAY_TAG=$(echo "$TAG_OUTPUT" | grep '^QUAY_TAG=' | tail -1 | cut -d'=' -f2)

    if [ -z "$QUAY_TAG" ]; then
        echo "❌ ERROR: Could not extract QUAY_TAG from script output!"
        echo "$TAG_OUTPUT"
        exit 1
    fi

    echo "Found tag: $QUAY_TAG"
    echo ""
else
    echo "Using provided QUAY_TAG: $QUAY_TAG"
    echo ""
fi

# Define image overrides
declare -A IMAGE_OVERRIDES=(
    ["RELATED_IMAGE_MAIN"]="${IMAGE_REGISTRY}/main:${QUAY_TAG}"
    ["RELATED_IMAGE_CENTRAL_DB"]="${IMAGE_REGISTRY}/central-db:${QUAY_TAG}"
    ["RELATED_IMAGE_SCANNER"]="${IMAGE_REGISTRY}/scanner:${QUAY_TAG}"
    ["RELATED_IMAGE_SCANNER_DB"]="${IMAGE_REGISTRY}/scanner-db:${QUAY_TAG}"
    ["RELATED_IMAGE_SCANNER_V4"]="${IMAGE_REGISTRY}/scanner-v4:${QUAY_TAG}"
    ["RELATED_IMAGE_SCANNER_V4_DB"]="${IMAGE_REGISTRY}/scanner-v4-db:${QUAY_TAG}"
)

echo "======================================"
echo "Image Overrides to Apply"
echo "======================================"
echo ""
for env_var in "${!IMAGE_OVERRIDES[@]}"; do
    echo "$env_var=${IMAGE_OVERRIDES[$env_var]}"
done
echo ""

# Build kubectl set env command
ENV_ARGS=()
for env_var in "${!IMAGE_OVERRIDES[@]}"; do
    ENV_ARGS+=("${env_var}=${IMAGE_OVERRIDES[$env_var]}")
done

echo "======================================"
echo "Applying to Operator Deployment"
echo "======================================"
echo ""
echo "Namespace: $OPERATOR_NAMESPACE"
echo "Deployment: $OPERATOR_DEPLOYMENT"
echo ""

# Apply the environment variables
if kubectl set env deployment/"$OPERATOR_DEPLOYMENT" \
    -n "$OPERATOR_NAMESPACE" \
    "${ENV_ARGS[@]}"; then
    echo ""
    echo "✅ Successfully applied image overrides!"
    echo ""
    echo "The operator will restart and pick up the new image configuration."
    echo "Any new Central deployments will use these images."
    echo ""
    echo "To apply to existing Central deployments, you may need to:"
    echo "  1. Delete the Central CR: kubectl delete central -n stackrox stackrox-central-services"
    echo "  2. Recreate it: kubectl apply -f your-central-cr.yaml"
    echo ""
else
    echo ""
    echo "❌ ERROR: Failed to apply image overrides!"
    exit 1
fi

# Wait for rollout
echo "Waiting for operator deployment to roll out..."
if kubectl rollout status deployment/"$OPERATOR_DEPLOYMENT" -n "$OPERATOR_NAMESPACE" --timeout=60s; then
    echo ""
    echo "✅ Operator deployment rolled out successfully!"
else
    echo ""
    echo "⚠️  Rollout status check timed out, but changes were applied."
    echo "   Check status with: kubectl get pods -n $OPERATOR_NAMESPACE"
fi

echo ""
echo "======================================"
echo "Verification"
echo "======================================"
echo ""
echo "Verify the environment variables:"
echo "  kubectl get deployment -n $OPERATOR_NAMESPACE $OPERATOR_DEPLOYMENT -o jsonpath='{.spec.template.spec.containers[0].env}' | jq -r '.[] | select(.name | startswith(\"RELATED_IMAGE\")) | \"\\(.name)=\\(.value)\"'"
echo ""
