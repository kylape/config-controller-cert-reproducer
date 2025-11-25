# CA Certificate Behavior in StackRox Central

## Certificate Types and Usage

### 1. mTLS (Internal Service-to-Service Communication)

- **Always uses operator's self-generated CA** stored in `central-tls` secret
- Created by operator in `operator/internal/central/extensions/reconcile_tls.go`
- Contains: `ca.pem`, `ca-key.pem`, `cert.pem`, `key.pem`, `jwt-key.pem`
- Used for internal communication between StackRox services (Central, Sensor, Scanner, etc.)
- **This CA never changes**, even when `defaultTLSSecret` is configured
- Changing this would break existing Sensor connections

### 2. defaultTLSSecret (Custom Serving Certificates)

- **This is how customers override Central's serving certificate**
- Configured via `spec.central.defaultTLSSecret.name` in Central CR
- Contains a `kubernetes.io/tls` secret with `tls.crt` and `tls.key`
- Mounted in Central pod at `/run/secrets/stackrox.io/default-tls-cert/`
- Central uses this certificate to **serve HTTPS/gRPC requests**
- **Important**: This does NOT affect mTLS - only external-facing serving certificate

### 3. additionalCAs

- Configured via `spec.tls.additionalCAs` in Central CR
- Operator creates `additional-ca` secret from this configuration
- Mounted in Central pod at `/usr/local/share/ca-certificates/`
- **Purpose**: Trust self-signed CAs from external services (e.g., external registries, auth providers)
- **NOT used** to determine Central's serving certificate
- Only mounted in Central pod, not in config-controller

## Central's Certificate Serving Behavior

Central is configured to serve **BOTH certificates simultaneously** by default (from `central/endpoints/defaults.go`):

```go
defaultServerCerts = []string{"default", "service"}
```

This means:
- `"default"` = custom certificate from `defaultTLSSecret` (if configured)
- `"service"` = operator-generated certificate from `central-tls`

### SNI-Based Certificate Selection

When a client connects to Central, **Go's TLS library selects which certificate to serve based on SNI (Server Name Indication)**:

1. **Client sends SNI** in the TLS handshake (e.g., `central.stackrox.svc`)
2. **Go checks certificates in order** (`["default", "service"]`)
3. **First certificate with matching SANs is selected**
4. **If no match, uses the first certificate** as fallback

**Critical implementation detail from `central/tlsconfig/manager_impl.go`:**

```go
for _, serverCert := range opts.ServerCerts {
    switch serverCert {
    case DefaultTLSCertSource:
        configurer.AddServerCertSource(&m.defaultCerts)  // Added FIRST
    case ServiceCertSource:
        configurer.AddServerCertSource(&m.internalCerts)  // Added SECOND
```

The custom certificate is added **first**, so it's checked before the operator certificate.

### Certificate Selection Examples

**Scenario 1: Custom cert with internal SANs** (TRIGGERS BUG)
- Custom cert SANs: `central.stackrox.svc`, `central.stackrox`, etc.
- Config-controller connects to: `central.stackrox.svc:443`
- SNI match: **YES** (custom cert SANs include `central.stackrox.svc`)
- Certificate served: **Custom certificate**
- Config-controller verification: **FAILS** (custom CA not in trust store before fix)

**Scenario 2: Custom cert with external-only SANs** (WORKS - e2e test scenario)
- Custom cert SANs: `central-external.example.com`, `custom-tls-cert.central.stackrox.local`
- Config-controller connects to: `central.stackrox.svc:443`
- SNI match: **NO** (custom cert SANs don't include `central.stackrox.svc`)
- Certificate served: **Operator certificate** (fallback)
- Config-controller verification: **SUCCEEDS** (operator CA in `/run/secrets/stackrox.io/certs/ca.pem`)

**Scenario 3: No custom cert configured**
- Only operator certificate available
- Config-controller connects to: `central.stackrox.svc:443`
- Certificate served: **Operator certificate** (only option)
- Config-controller verification: **SUCCEEDS**

## Why E2E Tests Don't Reproduce the Bug

E2E tests configure `defaultTLSSecret` but use **external-only SANs**:

From `tests/scripts/setup-certs.sh`:
```bash
setup_certs "$cert_dir" custom-tls-cert.central.stackrox.local "Server CA"
```

The certificate Common Name is `custom-tls-cert.central.stackrox.local`, which does **not** match the internal service name `central.stackrox.svc` that config-controller uses to connect.

**Result**: Central falls back to serving the operator certificate, config-controller can verify it, and everything works.

**Customer scenario**: Customers often include internal service names in their certificates for convenience:
- SANs: `central.stackrox.svc`, `central.stackrox`, `central`, etc.
- When config-controller connects, SNI matches
- Central serves custom certificate
- Config-controller crashes (before the fix)

## gRPC Central Client Certificate Verification

The config-controller connects to Central as a gRPC client. Certificate verification uses a two-stage fallback mechanism implemented in `pkg/clientconn/service_cert_fallback_verifier.go`:

### Verification Flow

**Without `defaultTLSSecret`:**

1. Central serves operator-generated certificate (signed by operator CA)
2. Client tries **system trust store** (`/etc/pki/ca-trust/`) → fails (operator CA not in system trust)
3. Client checks if cert is StackRox service cert → **yes** (has `ServiceCACommonName`)
4. Client falls back to `/run/secrets/stackrox.io/certs/ca.pem` (operator CA) → **succeeds** ✅

**With `defaultTLSSecret` + custom cert SANs include internal names (TRIGGERS BUG - before fix):**

1. Config-controller connects to `central.stackrox.svc:443`
2. Central's SNI-based selection: custom cert SANs match → **serves custom certificate**
3. Client tries **system trust store** → fails (custom CA not in system trust)
4. Client checks if cert is StackRox service cert → **no** (custom cert, not operator cert)
5. Client **does not** fall back to `/run/secrets/stackrox.io/certs/ca.pem` → **FAILS** ❌

**With `defaultTLSSecret` + custom cert SANs are external-only (e2e test scenario - before fix):**

1. Config-controller connects to `central.stackrox.svc:443`
2. Central's SNI-based selection: custom cert SANs don't match → **falls back to operator certificate**
3. Client tries **system trust store** → fails (operator CA not in system trust)
4. Client checks if cert is StackRox service cert → **yes** (operator cert)
5. Client falls back to `/run/secrets/stackrox.io/certs/ca.pem` (operator CA) → **succeeds** ✅

**With the fix (init container adds custom CA to system trust store):**

1. Init container copies `tls.crt` from `defaultTLSSecret` to `/etc/pki/ca-trust/source/anchors/` and runs `update-ca-trust extract`
   - The trust store is populated in an **emptyDir volume** that is shared between the init container (writable) and main container (read-only)
   - This emptyDir sharing is necessary because each container has its own filesystem - changes in the init container would not be visible to the main container without the shared volume
2. Main container mounts the populated `/etc/pki/ca-trust/` emptyDir (read-only)
3. **Regardless of which certificate Central serves**, client tries **system trust store** first
4. If custom cert is served: **succeeds** (custom CA now in system trust) ✅
5. If operator cert is served: falls back to `/run/secrets/stackrox.io/certs/ca.pem` → **succeeds** ✅

### Key Implementation Details

The config-controller init container (from `image/templates/helm/stackrox-central/templates/02-config-controller-02-deployment.yaml`):

- Only updates CA trust store when `defaultTLSSecret` is configured
- Mounts `defaultTLSSecret` at `/default-tls-cert/` (read-only)
- Mounts `etc-pki-volume` emptyDir at `/etc/pki/ca-trust/` (writable)
- Copies the certificate and runs `update-ca-trust extract` (built-in OS tool)

The config-controller main container:

- Mounts the same `etc-pki-volume` emptyDir at `/etc/pki/ca-trust/` (read-only)
- No code changes needed - transparently uses the system trust store

**Key Insight**: The `serviceCertFallbackVerifier` tries the system trust store **first**, then falls back to the operator CA at `/run/secrets/stackrox.io/certs/ca.pem`. This means:

- Custom CAs from `defaultTLSSecret` must be added to the system trust store
- The operator CA works via the fallback mechanism without needing to be in the system trust store
- `additionalCAs` is NOT needed for config-controller to trust Central - it's only for trusting _external_ services
