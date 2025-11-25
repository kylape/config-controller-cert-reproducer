#!/usr/bin/env bash
#
# setup-operator.sh
# Builds and deploys the StackRox operator from source
#
# Usage: ./setup-operator.sh [OPTIONS]
#   Options:
#     --registry REGISTRY    Image registry to use (default: kind-registry:5000)
#     --worktree PATH        Path to StackRox worktree (default: /root/workspace/worktrees/support-case)
#     --skip-build           Skip building the operator binary
#     --skip-push            Skip pushing the operator image
#

set -euo pipefail

# Default values
PUSH_REGISTRY="${PUSH_REGISTRY:-localhost:5001}"        # Registry for podman push
PULL_REGISTRY="${PULL_REGISTRY:-kind-registry:5000}"    # Registry for kubectl (in-cluster)
IMAGE_REPO="${IMAGE_REPO:-stackrox/operator}"            # Image repository name
WORKTREE_DIR="${WORKTREE_DIR:-$(pwd)}"
QUAY_TAG="${QUAY_TAG:-}"
SKIP_BUILD=false
SKIP_PUSH=false
SKIP_IMAGE_CONFIG=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --push-registry)
            PUSH_REGISTRY="$2"
            shift 2
            ;;
        --pull-registry)
            PULL_REGISTRY="$2"
            shift 2
            ;;
        --registry)
            # Convenience: set both to same value
            PUSH_REGISTRY="$2"
            PULL_REGISTRY="$2"
            shift 2
            ;;
        --image-repo)
            IMAGE_REPO="$2"
            shift 2
            ;;
        --worktree)
            WORKTREE_DIR="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-push)
            SKIP_PUSH=true
            shift
            ;;
        --skip-image-config)
            SKIP_IMAGE_CONFIG=true
            shift
            ;;
        --quay-tag)
            QUAY_TAG="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --registry REGISTRY         Set both push and pull registry (convenience)"
            echo "  --push-registry REGISTRY    Registry for podman push (default: localhost:5001)"
            echo "  --pull-registry REGISTRY    Registry for kubectl/in-cluster (default: kind-registry:5000)"
            echo "  --image-repo REPO           Image repository name (default: stackrox/operator)"
            echo "  --worktree PATH             Path to StackRox repository (default: current directory)"
            echo "  --quay-tag TAG              QUAY_TAG for Central images (e.g., 4.10.x-415-gd1af0f418d)"
            echo "  --skip-build                Skip building the operator binary"
            echo "  --skip-push                 Skip pushing the operator image"
            echo "  --skip-image-config         Skip configuring Central component images"
            echo "  -h, --help                  Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  PUSH_REGISTRY               Override default push registry"
            echo "  PULL_REGISTRY               Override default pull registry"
            echo "  IMAGE_REPO                  Override default image repository"
            echo "  WORKTREE_DIR                Override default StackRox repository path"
            echo "  QUAY_TAG                    Image tag for Central components"
            echo ""
            echo "Example usage:"
            echo "  # From StackRox repository root:"
            echo "  cd /path/to/stackrox"
            echo "  /path/to/reproducer/setup-operator.sh --quay-tag 4.10.x-415-gd1af0f418d"
            echo ""
            echo "  # With custom registries:"
            echo "  /path/to/reproducer/setup-operator.sh --push-registry localhost:5001 --pull-registry kind-registry:5000 --quay-tag 4.10.x-415-gd1af0f418d"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run '$0 --help' for usage information"
            exit 1
            ;;
    esac
done

# Image details
PUSH_IMAGE="${PUSH_REGISTRY}/${IMAGE_REPO}:latest"
PULL_IMAGE="${PULL_REGISTRY}/${IMAGE_REPO}:latest"
OPERATOR_NAMESPACE="rhacs-operator-system"
OPERATOR_DEPLOYMENT="rhacs-operator-controller-manager"

echo "========================================"
echo "StackRox Operator Setup"
echo "========================================"
echo ""
echo "Configuration:"
echo "  StackRox Repo:  $WORKTREE_DIR"
echo "  Push Registry:  $PUSH_REGISTRY"
echo "  Pull Registry:  $PULL_REGISTRY"
echo "  Image Repo:     $IMAGE_REPO"
echo "  Push Image:     $PUSH_IMAGE"
echo "  Pull Image:     $PULL_IMAGE"
echo ""

# Validate StackRox repository exists
if [ ! -d "$WORKTREE_DIR" ]; then
    echo "❌ ERROR: StackRox repository not found: $WORKTREE_DIR"
    echo ""
    echo "Please run this script from the StackRox repository root:"
    echo "  cd /path/to/stackrox"
    echo "  /path/to/reproducer/setup-operator.sh"
    echo ""
    echo "Or specify the repository location:"
    echo "  $0 --worktree /path/to/stackrox"
    exit 1
fi

# Verify it looks like the StackRox repository
if [ ! -f "$WORKTREE_DIR/scripts/go-build.sh" ]; then
    echo "❌ ERROR: Directory doesn't appear to be the StackRox repository: $WORKTREE_DIR"
    echo "   Missing: scripts/go-build.sh"
    echo ""
    echo "Please ensure you're pointing to the StackRox repository root."
    exit 1
fi

cd "$WORKTREE_DIR"

# Step 1: Build operator binary
if [ "$SKIP_BUILD" = false ]; then
    echo "========================================"
    echo "Step 1: Building Operator Binary"
    echo "========================================"
    echo ""

    # Detect architecture
    GOARCH=$(go env GOARCH)
    GOOS=$(go env GOOS)

    echo "Building for $GOOS/$GOARCH..."
    GOOS=$GOOS GOARCH=$GOARCH scripts/go-build.sh operator/cmd/main.go

    if [ ! -f "bin/${GOOS}_${GOARCH}/main" ]; then
        echo "❌ ERROR: Binary not found at bin/${GOOS}_${GOARCH}/main"
        exit 1
    fi

    echo "✅ Operator binary built successfully"
    echo ""
else
    echo "⏭️  Skipping binary build (--skip-build)"
    echo ""
fi

# Step 2: Create Dockerfile for current architecture
GOARCH=$(go env GOARCH)
GOOS=$(go env GOOS)

echo "Creating operator.Dockerfile for ${GOOS}/${GOARCH}..."
cat > operator.Dockerfile <<EOF
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

# Create non-root user
RUN microdnf install -y shadow-utils && \
    useradd -u 65532 -r -g 0 -s /sbin/nologin nonroot && \
    microdnf clean all

COPY bin/${GOOS}_${GOARCH}/main /operator
RUN chmod +x /operator

USER 65532:0

ENTRYPOINT ["/operator"]
EOF
echo "✅ Created operator.Dockerfile"
echo ""

# Step 3: Build container image
echo "========================================"
echo "Step 2: Building Container Image"
echo "========================================"
echo ""

podman build -t "$PUSH_IMAGE" -f operator.Dockerfile .

echo "✅ Container image built successfully"
echo ""

# Step 4: Push image to registry
if [ "$SKIP_PUSH" = false ]; then
    echo "========================================"
    echo "Step 3: Pushing Image to Registry"
    echo "========================================"
    echo ""

    # Check if registry is local (kind-registry or localhost)
    if [[ "$PUSH_REGISTRY" == *"kind-registry"* ]] || [[ "$PUSH_REGISTRY" == "localhost"* ]]; then
        echo "Pushing to local registry (disabling TLS verification)..."
        podman push --tls-verify=false "$PUSH_IMAGE"
    else
        echo "Pushing to remote registry..."
        podman push "$PUSH_IMAGE"
    fi

    echo "✅ Image pushed successfully"
    echo ""
else
    echo "⏭️  Skipping image push (--skip-push)"
    echo ""
fi

# Step 5: Install CRDs
echo "========================================"
echo "Step 4: Installing Operator CRDs"
echo "========================================"
echo ""

cd operator
make install

echo "✅ CRDs installed successfully"
echo ""

# Step 6: Deploy operator
echo "========================================"
echo "Step 5: Deploying Operator"
echo "========================================"
echo ""

# Check if operator is already deployed
if kubectl get deployment -n "$OPERATOR_NAMESPACE" "$OPERATOR_DEPLOYMENT" >/dev/null 2>&1; then
    echo "Operator already deployed, updating image..."
    kubectl -n "$OPERATOR_NAMESPACE" set image "deploy/$OPERATOR_DEPLOYMENT" "*=$PULL_IMAGE"
else
    echo "Deploying operator..."
    make deploy

    # Wait a moment for deployment to be created
    sleep 2

    # Update the image to use the pull registry
    kubectl -n "$OPERATOR_NAMESPACE" set image "deploy/$OPERATOR_DEPLOYMENT" "*=$PULL_IMAGE"
fi

echo "✅ Operator deployed successfully"
echo ""

# Step 7: Wait for operator to be ready
echo "========================================"
echo "Step 6: Waiting for Operator"
echo "========================================"
echo ""

echo "Waiting for operator deployment to be ready..."
if kubectl wait --for=condition=Available --timeout=120s \
    -n "$OPERATOR_NAMESPACE" "deploy/$OPERATOR_DEPLOYMENT"; then
    echo "✅ Operator is ready!"
else
    echo "⚠️  Operator deployment did not become ready within timeout"
    echo "   Check status with: kubectl get pods -n $OPERATOR_NAMESPACE"
fi

echo ""

# Step 8: Configure Central component images
if [ "$SKIP_IMAGE_CONFIG" = false ]; then
    echo "========================================"
    echo "Step 7: Configuring Central Images"
    echo "========================================"
    echo ""

    if [ -z "$QUAY_TAG" ]; then
        echo "⚠️  QUAY_TAG not set, skipping image configuration"
        echo ""
        echo "To configure Central component images later, run:"
        echo "  export QUAY_TAG=4.10.x-415-gd1af0f418d"
        echo "  ./set-operator-image-overrides.sh"
        echo ""
    else
        echo "Configuring operator with Central images from quay.io/stackrox-io:$QUAY_TAG..."
        echo ""

        # Define image overrides
        declare -A IMAGE_OVERRIDES=(
            ["RELATED_IMAGE_MAIN"]="quay.io/stackrox-io/main:${QUAY_TAG}"
            ["RELATED_IMAGE_CENTRAL_DB"]="quay.io/stackrox-io/central-db:${QUAY_TAG}"
            ["RELATED_IMAGE_SCANNER"]="quay.io/stackrox-io/scanner:${QUAY_TAG}"
            ["RELATED_IMAGE_SCANNER_DB"]="quay.io/stackrox-io/scanner-db:${QUAY_TAG}"
            ["RELATED_IMAGE_SCANNER_V4"]="quay.io/stackrox-io/scanner-v4:${QUAY_TAG}"
            ["RELATED_IMAGE_SCANNER_V4_DB"]="quay.io/stackrox-io/scanner-v4-db:${QUAY_TAG}"
        )

        # Build kubectl set env command
        ENV_ARGS=()
        for env_var in "${!IMAGE_OVERRIDES[@]}"; do
            ENV_ARGS+=("${env_var}=${IMAGE_OVERRIDES[$env_var]}")
            echo "  $env_var=${IMAGE_OVERRIDES[$env_var]}"
        done
        echo ""

        # Apply the environment variables
        if kubectl set env deployment/"$OPERATOR_DEPLOYMENT" \
            -n "$OPERATOR_NAMESPACE" \
            "${ENV_ARGS[@]}"; then
            echo "✅ Image overrides applied successfully"
            echo ""

            # Wait for rollout
            echo "Waiting for operator to roll out with new configuration..."
            kubectl rollout status deployment/"$OPERATOR_DEPLOYMENT" -n "$OPERATOR_NAMESPACE" --timeout=60s || true
            echo ""
        else
            echo "❌ Failed to apply image overrides"
        fi
    fi
else
    echo "⏭️  Skipping image configuration (--skip-image-config)"
    echo ""
fi

echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""
echo "Operator Details:"
echo "  Namespace:   $OPERATOR_NAMESPACE"
echo "  Deployment:  $OPERATOR_DEPLOYMENT"
echo "  Image:       $PULL_IMAGE"
echo ""

if [ -n "$QUAY_TAG" ] && [ "$SKIP_IMAGE_CONFIG" = false ]; then
    echo "Central Images: quay.io/stackrox-io/*:$QUAY_TAG"
    echo ""
    echo "Next steps:"
    echo "  Run reproducer: make run"
else
    echo "Next steps:"
    echo "  1. Configure Central images: export QUAY_TAG=<tag> && ./set-operator-image-overrides.sh"
    echo "  2. Run reproducer: make run"
fi

echo ""
echo "Verify operator:"
echo "  kubectl get pods -n $OPERATOR_NAMESPACE"
echo "  kubectl logs -n $OPERATOR_NAMESPACE -l control-plane=controller-manager"
echo ""
