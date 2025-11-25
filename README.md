# Config-Controller Crash Reproducer

This is a self-contained reproducer for a bug in StackRox where `config-controller` crashes when Central is configured with custom TLS certificates via `additionalCAs`.

## Problem Description

When a StackRox Central CR is configured with:
1. Custom serving certificates (`spec.central.defaultTLSSecret`)
2. The CA for those certificates in `spec.tls.additionalCAs`

The `config-controller` pod crashes with:
```
x509: certificate signed by unknown authority
```

### Root Cause

The StackRox operator:
- Creates an `additional-ca` secret from `spec.tls.additionalCAs`
- Mounts this secret in the Central pod at `/usr/local/share/ca-certificates/`
- **Does NOT mount** this secret in the config-controller pod

Config-controller only trusts:
- System CA bundle
- `/run/secrets/stackrox.io/certs/ca.pem` (from `central-tls` secret)

Since the custom CA is only in the `additional-ca` secret (not mounted in config-controller), config-controller cannot verify Central's TLS certificate.

## Prerequisites

* Kubernetes cluster (tested with KinD)
* cert-manager installed
* **StackRox source code cloned** from https://github.com/stackrox/stackrox
* Go 1.22 or later
* Podman or Docker
* kubectl configured for your cluster

**Important:** You need to have the StackRox repository checked out locally, as `setup-operator.sh` uses build scripts from the repository to build the operator binary.

## Quick Start (TL;DR)

```bash
# 0. Clone StackRox repository (if not already done)
git clone https://github.com/stackrox/stackrox
cd stackrox

# 1. Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager -n cert-manager

# 2. Build, deploy operator, and configure images
export QUAY_TAG=4.10.x-415-gd1af0f418d
/path/to/config-controller-reproducer/setup-operator.sh --quay-tag "$QUAY_TAG"

# For custom registry setup (e.g., KinD):
# /path/to/config-controller-reproducer/setup-operator.sh \
#   --push-registry localhost:5001 \
#   --pull-registry kind-registry:5000 \
#   --quay-tag "$QUAY_TAG"

# 3. Run reproducer
cd /path/to/config-controller-reproducer
make run
```

## Complete Setup Guide

This reproducer provides a turnkey setup that takes you from nothing to a fully working reproducer.

### 1. Install Prerequisites

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available --timeout=300s \
  deployment/cert-manager -n cert-manager
```

### 2. Build, Deploy Operator, and Configure Images

The setup script handles everything in one step. **Important:** Run the script from the StackRox repository root directory.

```bash
# Clone the StackRox repository if you haven't already
git clone https://github.com/stackrox/stackrox
cd stackrox

# Set Central component tag
export QUAY_TAG=4.10.x-415-gd1af0f418d      # Valid tag from master

# Run the all-in-one setup script from the stackrox repo root
/path/to/config-controller-reproducer/setup-operator.sh --quay-tag "$QUAY_TAG"
```

The script uses sensible defaults:
* **Push Registry**: `localhost:5001` (for `podman push`)
* **Pull Registry**: `kind-registry:5000` (for in-cluster pulls)
* **Image Repo**: `stackrox/operator`

**Custom Registry Setup:**

For different environments, you can specify custom registries:

```bash
# KinD with local registry
./setup-operator.sh \
  --push-registry localhost:5001 \
  --pull-registry kind-registry:5000 \
  --quay-tag 4.10.x-415-gd1af0f418d

# Same registry for both push and pull
./setup-operator.sh \
  --registry my-registry:5000 \
  --quay-tag 4.10.x-415-gd1af0f418d

# Custom image repository
./setup-operator.sh \
  --image-repo myorg/custom-operator \
  --quay-tag 4.10.x-415-gd1af0f418d
```

By default, the script will look for the StackRox repository at the current directory or use `--worktree` to specify a different location.

This single command will:
1. **Build the operator binary** for your architecture using `scripts/go-build.sh`
2. **Create a container image** with UBI9 minimal base
3. **Push to your registry** (handles local registries with `--tls-verify=false`)
4. **Install operator CRDs** via `make install`
5. **Deploy the operator** via `make deploy`
6. **Update deployment image** to use your built image
7. **Configure Central images** with public `quay.io/stackrox-io` images
8. **Wait for operator** to be ready

For KinD clusters, the registry is typically `kind-registry:5000`. For other local setups, you might use `localhost:5001`.

To find a valid `QUAY_TAG`, look for successful builds in the StackRox CI/CD pipeline from origin/master, or check recent tags in the public quay.io repository.

**Advanced usage:**

```bash
# Use custom worktree location
./setup-operator.sh --worktree /path/to/stackrox --registry kind-registry:5000 --quay-tag 4.10.x-415-gd1af0f418d

# Skip build if binary already exists
./setup-operator.sh --skip-build --quay-tag 4.10.x-415-gd1af0f418d

# Skip push if image already in registry
./setup-operator.sh --skip-push --quay-tag 4.10.x-415-gd1af0f418d

# Skip image configuration (configure later manually)
./setup-operator.sh --skip-image-config

# Configure images later if skipped
export QUAY_TAG=4.10.x-415-gd1af0f418d
./set-operator-image-overrides.sh
```

### 3. Run the Reproducer

```bash
# Build and run
make run

# Or manually
go build -o bin/reproducer .
./bin/reproducer
```

### 3. Observe the Crash

```bash
# Watch config-controller pods
kubectl get pods -n stackrox -l app=config-controller -w

# View logs
kubectl logs -n stackrox -l app=config-controller --tail=50 -f
```

Expected output:
```
pkg/client: could not exchange token: Failed to exchange token:
rpc error: code = Unavailable desc = connection error:
desc = "transport: authentication handshake failed:
x509: certificate signed by unknown authority"
```

### 4. Restore Environment

```bash
# Delete the Central CR (operator will clean up)
make restore

# Or manually
./bin/reproducer -restore
```

## How It Works

The reproducer:

1. **Creates a custom CA** using cert-manager `ClusterIssuer` with self-signed certificates
2. **Generates Central TLS certificates** signed by the custom CA
3. **Creates a Central CR** with:
   ```yaml
   spec:
     central:
       defaultTLSSecret:
         name: openshift-rhacs-certificates  # Custom cert
     tls:
       additionalCAs:
         - name: custom-ca.crt
           content: <CA certificate PEM>
   ```
4. **Operator processes the CR** and:
   - Creates `additional-ca` secret from `spec.tls.additionalCAs`
   - Deploys Central with custom serving cert
   - Deploys Central with `additional-ca` volume mounted
   - Deploys config-controller **without** `additional-ca` volume mounted ❌
5. **Config-controller crashes** because it cannot verify Central's certificate

## Project Structure

```
.
├── main.go                          # Main reproducer logic (uses typed Central API)
├── go.mod                           # Go module definition
├── Makefile                         # Build automation
├── setup-operator.sh                # Script to build and deploy operator
├── set-operator-image-overrides.sh  # Script to configure operator images
└── README.md                        # This file
```

## Code Overview

**`main.go`** - Main reproducer:
* Uses typed Central API from `github.com/stackrox/rox/operator/api/v1alpha1` for type safety
* Uses cert-manager Go API to create certificates dynamically
* Uses dynamic Kubernetes client to create Central CR
* Implements proper wait logic for certificate readiness
* Provides both reproduce and restore functionality

**`setup-operator.sh`** - Operator deployment automation:
* Builds operator binary for current architecture using `scripts/go-build.sh`
* Creates minimal container image with UBI9 base
* Pushes to configurable registry (handles local registries)
* Installs CRDs and deploys operator
* Updates deployment with custom-built image

**`set-operator-image-overrides.sh`** - Image configuration:
* Sets `RELATED_IMAGE_*` environment variables on operator deployment
* Supports `QUAY_TAG` environment variable or auto-detection (if available)
* Uses public `quay.io/stackrox-io` registry for Central components

## Configuration

The reproducer uses these names (configurable in code):

```go
const (
    namespace         = "stackrox"
    centralCRName     = "stackrox-central-services"
    centralSecretName = "openshift-rhacs-certificates"
    caSecretName      = "custom-ca-secret"
)
```

## Advanced Usage

### Use Custom Kubeconfig

```bash
./bin/reproducer -kubeconfig ~/.kube/my-cluster-config
```

### Restore Environment

```bash
./bin/reproducer -restore
```

This deletes the Central CR, and the operator will clean up all resources.

### Manual Cleanup

If needed, manually delete cert-manager resources:

```bash
kubectl delete certificate -n stackrox custom-ca central-tls-custom
kubectl delete issuer -n stackrox custom-ca-issuer
kubectl delete clusterissuer custom-ca-issuer-selfsigned
```

## Verification

After running the reproducer:

1. **Check Central pod** - should have `additional-ca` volume:
   ```bash
   kubectl get pod -n stackrox -l app=central -o yaml | grep -A5 additional-ca-volume
   ```

2. **Check config-controller pod** - should NOT have `additional-ca` volume:
   ```bash
   kubectl get pod -n stackrox -l app=config-controller -o yaml | grep -A5 volumeMounts
   ```

3. **Check config-controller logs** for the error:
   ```bash
   kubectl logs -n stackrox -l app=config-controller | grep "x509"
   ```

## Expected Fix

The fix would involve updating the operator to mount `additional-ca-volume` in config-controller:

```yaml
# In config-controller deployment template
volumeMounts:
- name: additional-ca-volume
  mountPath: /usr/local/share/ca-certificates/
  readOnly: true

volumes:
- name: additional-ca-volume
  secret:
    secretName: additional-ca
    optional: true
```

## License

This reproducer is provided as-is for debugging purposes.

## Related Issues

* Customer ticket: RHACS using custom CA + backup/restore
* Component: config-controller
* Error: `x509: certificate signed by unknown authority`
