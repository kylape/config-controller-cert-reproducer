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
* cert-manager installed and running
* StackRox operator installed and running
* Go 1.22 or later (for building)

## Quick Start

### 1. Install Prerequisites

```bash
# Install cert-manager (if not already installed)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available --timeout=300s \
  deployment/cert-manager -n cert-manager

# Install StackRox operator
# (User should install operator according to StackRox documentation)
```

### 2. Run the Reproducer

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
├── main.go           # Main reproducer logic
├── go.mod            # Go module definition
├── Makefile          # Build automation
└── README.md         # This file
```

## Code Overview

The `main.go` file:

* Uses the cert-manager Go API to create certificates dynamically
* Uses dynamic Kubernetes client to create Central CR
* Implements proper wait logic for certificate readiness
* Provides both reproduce and restore functionality

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
