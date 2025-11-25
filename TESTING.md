# Testing Guide

This guide walks through testing the config-controller crash reproducer.

## Prerequisites Checklist

- [ ] Kubernetes cluster running (KinD, OpenShift, etc.)
- [ ] cert-manager installed and healthy
- [ ] StackRox operator installed and running
- [ ] `kubectl` configured to access the cluster
- [ ] Go 1.22+ installed (for building from source)

## Step 1: Install cert-manager

If cert-manager is not already installed:

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available --timeout=300s \
  deployment/cert-manager -n cert-manager \
  deployment/cert-manager-webhook -n cert-manager \
  deployment/cert-manager-cainjector -n cert-manager

# Verify cert-manager is running
kubectl get pods -n cert-manager
```

Expected output:
```
NAME                                      READY   STATUS    RESTARTS   AGE
cert-manager-xxxxxxxxx-xxxxx              1/1     Running   0          1m
cert-manager-cainjector-xxxxxxxxx-xxxxx   1/1     Running   0          1m
cert-manager-webhook-xxxxxxxxx-xxxxx      1/1     Running   0          1m
```

## Step 2: Install StackRox Operator

The operator must be installed before running the reproducer. Follow the official StackRox operator installation guide.

For OLM-based installation:
```bash
# This varies by platform - consult StackRox documentation
kubectl create namespace rhacs-operator
# ... follow operator installation steps
```

Verify the operator is running:
```bash
kubectl get pods -n rhacs-operator
```

## Step 3: Build the Reproducer

```bash
cd config-controller-reproducer

# Download dependencies
make deps

# Build
make build
```

This creates `bin/reproducer`.

## Step 4: Run the Reproducer

```bash
make run
```

Or manually:
```bash
./bin/reproducer
```

### Expected Output

```
[2025-11-24 15:00:00] === Config-Controller Crash Reproducer ===
[2025-11-24 15:00:00]
[2025-11-24 15:00:00] This reproducer will:
[2025-11-24 15:00:00] 1. Create a custom CA using cert-manager
[2025-11-24 15:00:00] 2. Generate Central serving certificates from that CA
[2025-11-24 15:00:00] 3. Create a Central CR with:
[2025-11-24 15:00:00]    - Custom serving cert (spec.central.defaultTLSSecret)
[2025-11-24 15:00:00]    - Custom CA in additionalCAs (spec.tls.additionalCAs)
[2025-11-24 15:00:00] 4. Config-controller should crash because:
[2025-11-24 15:00:00]    - Central serves with custom cert
[2025-11-24 15:00:00]    - Custom CA is in additional-ca secret
[2025-11-24 15:00:00]    - Config-controller does NOT mount additional-ca secret
[2025-11-24 15:00:00]
[2025-11-24 15:00:01] Ensuring namespace stackrox exists...
[2025-11-24 15:00:01] ✓ Namespace created
[2025-11-24 15:00:01] Creating cert-manager resources...
[2025-11-24 15:00:01] ✓ Cert-manager resources created
[2025-11-24 15:00:01] Waiting for certificate custom-ca to be ready...
[2025-11-24 15:00:03] ✓ Certificate custom-ca is ready
[2025-11-24 15:00:03] Waiting for certificate central-tls-custom to be ready...
[2025-11-24 15:00:05] ✓ Certificate central-tls-custom is ready
[2025-11-24 15:00:05] Retrieving CA certificate content...
[2025-11-24 15:00:05] ✓ CA certificate retrieved
[2025-11-24 15:00:05] Creating Central CR...
[2025-11-24 15:00:06] ✓ Central CR created
[2025-11-24 15:00:06]
[2025-11-24 15:00:06] === Setup Complete ===
[2025-11-24 15:00:06]
[2025-11-24 15:00:06] The Central CR has been created with:
[2025-11-24 15:00:06]   - Custom serving cert: openshift-rhacs-certificates
[2025-11-24 15:00:06]   - Additional CA configured in spec.tls.additionalCAs
[2025-11-24 15:00:06]
[2025-11-24 15:00:06] Expected behavior:
[2025-11-24 15:00:06]   - Operator will create additional-ca secret from spec.tls.additionalCAs
[2025-11-24 15:00:06]   - Operator will mount additional-ca in Central pod
[2025-11-24 15:00:06]   - Operator will NOT mount additional-ca in config-controller pod
[2025-11-24 15:00:06]   - Config-controller will crash with: x509: certificate signed by unknown authority
[2025-11-24 15:00:06]
[2025-11-24 15:00:06] Monitor with:
[2025-11-24 15:00:06]   kubectl get pods -n stackrox -l app=config-controller
[2025-11-24 15:00:06]   kubectl logs -n stackrox -l app=config-controller --tail=50
```

## Step 5: Verify the Issue

### Check Central CR Status

```bash
kubectl get central -n stackrox stackrox-central-services -o yaml
```

Look for the `spec.tls.additionalCAs` section.

### Check Secrets Created

```bash
# Check that additional-ca secret was created by the operator
kubectl get secret -n stackrox additional-ca

# View the content
kubectl get secret -n stackrox additional-ca -o yaml
```

### Check Central Pod

Verify Central has the `additional-ca` volume mounted:

```bash
kubectl get pod -n stackrox -l app=central -o yaml | grep -A10 additional-ca-volume
```

Expected output:
```yaml
- name: additional-ca-volume
  mountPath: /usr/local/share/ca-certificates/
  readOnly: true
...
- name: additional-ca-volume
  secret:
    secretName: additional-ca
    optional: true
```

### Check Config-Controller Pod

Verify config-controller does NOT have the `additional-ca` volume:

```bash
kubectl get pod -n stackrox -l app=config-controller -o yaml | grep -A10 volumeMounts
```

You should see only:
```yaml
volumeMounts:
- mountPath: /run/secrets/stackrox.io/certs/
  name: central-certs-volume
  readOnly: true
```

No `additional-ca-volume` mounted!

### Check Config-Controller Logs

```bash
kubectl logs -n stackrox -l app=config-controller --tail=100
```

Expected error (may take a few minutes to appear):
```
pkg/client: 2025/11/24 15:05:00.123456 client.go:247: Warn: Initialization Error: could not exchange token: Failed to exchange token: rpc error: code = Unavailable desc = connection error: desc = "transport: authentication handshake failed: x509: certificate signed by unknown authority"
```

### Check Pod Status

```bash
kubectl get pods -n stackrox -l app=config-controller
```

The pod may enter `CrashLoopBackOff` or remain in `Running` but continuously log errors.

## Step 6: Restore Environment

```bash
make restore
```

Or manually:
```bash
./bin/reproducer -restore
```

This deletes the Central CR, and the operator will clean up all StackRox resources.

### Manual Cleanup (if needed)

```bash
# Delete cert-manager resources
kubectl delete certificate -n stackrox custom-ca central-tls-custom
kubectl delete issuer -n stackrox custom-ca-issuer
kubectl delete clusterissuer custom-ca-issuer-selfsigned

# Delete secrets (if operator didn't clean them up)
kubectl delete secret -n stackrox additional-ca custom-ca-secret openshift-rhacs-certificates
```

## Troubleshooting

### cert-manager certificates not becoming ready

Check cert-manager logs:
```bash
kubectl logs -n cert-manager -l app=cert-manager --tail=100
```

Describe the certificate:
```bash
kubectl describe certificate -n stackrox custom-ca
kubectl describe certificate -n stackrox central-tls-custom
```

### Central CR not being processed

Check operator logs:
```bash
kubectl logs -n rhacs-operator -l app=rhacs-operator --tail=100
```

### Config-controller not crashing

1. Verify Central is using the custom cert:
   ```bash
   kubectl get pod -n stackrox -l app=central -o yaml | grep -A5 "defaultTLSSecret"
   ```

2. Verify the custom CA is in additional-ca:
   ```bash
   kubectl get secret -n stackrox additional-ca -o jsonpath='{.data}'
   ```

3. Wait longer - it may take 5-10 minutes for config-controller to try connecting

## Success Criteria

The reproducer is successful when:

1. ✅ Central CR is created with custom TLS config
2. ✅ Operator creates `additional-ca` secret
3. ✅ Central pod has `additional-ca-volume` mounted
4. ✅ Config-controller pod does NOT have `additional-ca-volume` mounted
5. ✅ Config-controller logs show `x509: certificate signed by unknown authority`

## Next Steps

After reproducing the issue, the fix would be to update the operator to mount `additional-ca` in config-controller.
