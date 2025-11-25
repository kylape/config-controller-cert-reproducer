package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/pkg/errors"
	platform "github.com/stackrox/rox/operator/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

const (
	namespace         = "stackrox"
	caIssuerName      = "custom-ca-issuer-selfsigned"
	caCertName        = "custom-ca"
	caSecretName      = "custom-ca-secret"
	centralCertName   = "central-tls-custom"
	centralSecretName = "openshift-rhacs-certificates"
	centralCRName     = "stackrox-central-services"
)

var (
	kubeconfig        string
	restore           bool
	includeInternalSANs bool
)

func init() {
	// Default to KUBECONFIG env var if set
	defaultKubeconfig := os.Getenv("KUBECONFIG")
	flag.StringVar(&kubeconfig, "kubeconfig", defaultKubeconfig, "Path to kubeconfig file (defaults to KUBECONFIG env var)")
	flag.BoolVar(&restore, "restore", false, "Restore by deleting the Central CR")
	flag.BoolVar(&includeInternalSANs, "include-internal-sans", false, "Include internal service names (central.stackrox.svc) in certificate SANs (triggers the bug)")
}

func main() {
	flag.Parse()

	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	ctx := context.Background()

	// Load kubeconfig
	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return errors.Wrap(err, "failed to load kubeconfig")
	}

	// Create clients
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return errors.Wrap(err, "failed to create kubernetes client")
	}

	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return errors.Wrap(err, "failed to create dynamic client")
	}

	if restore {
		return doRestore(ctx, dynamicClient)
	}

	return doReproduce(ctx, clientset, dynamicClient)
}

func doRestore(ctx context.Context, dynamicClient dynamic.Interface) error {
	log("=== Restoring Environment ===")

	centralGVR := schema.GroupVersionResource{
		Group:    "platform.stackrox.io",
		Version:  "v1alpha1",
		Resource: "centrals",
	}

	log("Deleting Central CR: %s", centralCRName)
	err := dynamicClient.Resource(centralGVR).Namespace(namespace).Delete(ctx, centralCRName, metav1.DeleteOptions{})
	if err != nil && !apierrors.IsNotFound(err) {
		return errors.Wrap(err, "failed to delete Central CR")
	}

	log("✓ Central CR deleted (operator will clean up resources)")
	log("")
	log("Note: The operator will delete all StackRox resources.")
	log("You may also want to delete cert-manager resources:")
	log("  kubectl delete certificate -n %s %s %s", namespace, caCertName, centralCertName)
	log("  kubectl delete clusterissuer %s", caIssuerName)

	return nil
}

func doReproduce(ctx context.Context, clientset *kubernetes.Clientset, dynamicClient dynamic.Interface) error {
	log("=== Config-Controller Crash Reproducer ===")
	log("")
	log("This reproducer will:")
	log("1. Create a custom CA using cert-manager")
	log("2. Generate Central serving certificates from that CA")
	if includeInternalSANs {
		log("   - Certificate will include internal SANs: central.stackrox.svc, etc.")
		log("   - This triggers the bug: Central selects custom cert, config-controller can't verify it")
	} else {
		log("   - Certificate will use external-only SANs")
		log("   - This may NOT trigger the bug: Central falls back to operator cert")
	}
	log("3. Create a Central CR with:")
	log("   - Custom serving cert (spec.central.defaultTLSSecret)")
	log("   - Custom CA in additionalCAs (spec.tls.additionalCAs)")
	log("4. Expected behavior:")
	if includeInternalSANs {
		log("   - Central serves custom cert (matches SNI: central.stackrox.svc)")
		log("   - Config-controller cannot verify it (doesn't trust custom CA)")
		log("   - Config-controller crashes with: x509: certificate signed by unknown authority")
	} else {
		log("   - Central serves operator cert (custom cert doesn't match SNI)")
		log("   - Config-controller can verify it (trusts operator CA)")
		log("   - Config-controller works (bug not triggered)")
	}
	log("")

	// Step 1: Ensure namespace exists
	if err := ensureNamespace(ctx, clientset); err != nil {
		return err
	}

	// Step 2: Create cert-manager resources
	if err := createCertManagerResources(ctx, dynamicClient); err != nil {
		return err
	}

	// Step 3: Wait for certificates to be ready
	if err := waitForCertificate(ctx, dynamicClient, caCertName); err != nil {
		return err
	}
	if err := waitForCertificate(ctx, dynamicClient, centralCertName); err != nil {
		return err
	}

	// Step 4: Get the CA certificate content
	caCert, err := getCACertContent(ctx, clientset)
	if err != nil {
		return err
	}

	// Step 5: Create Central CR
	if err := createCentralCR(ctx, dynamicClient, caCert); err != nil {
		return err
	}

	log("")
	log("=== Setup Complete ===")
	log("")
	log("The Central CR has been created with:")
	log("  - Custom serving cert: %s", centralSecretName)
	if includeInternalSANs {
		log("  - Certificate includes internal SANs (central.%s.svc, etc.)", namespace)
	} else {
		log("  - Certificate uses external-only SANs (central-external.example.com)")
	}
	log("  - Additional CA configured in spec.tls.additionalCAs")
	log("")
	log("Expected behavior:")
	log("  - Operator will create additional-ca secret from spec.tls.additionalCAs")
	log("  - Operator will mount additional-ca in Central pod")
	log("  - Operator will NOT mount additional-ca in config-controller pod")
	if includeInternalSANs {
		log("  - Config-controller connects to central.%s.svc:443", namespace)
		log("  - Central serves custom cert (SNI matches)")
		log("  - Config-controller crashes with: x509: certificate signed by unknown authority")
	} else {
		log("  - Config-controller connects to central.%s.svc:443", namespace)
		log("  - Central serves operator cert (custom cert SNI doesn't match)")
		log("  - Config-controller works normally (bug not triggered)")
	}
	log("")
	log("Monitor with:")
	log("  kubectl get pods -n %s -w", namespace)
	log("  kubectl get pods -n %s -l app=config-controller", namespace)
	log("  kubectl logs -n %s -l app=config-controller --tail=50", namespace)
	log("")
	log("Check certificate details:")
	log("  kubectl get certificate -n %s %s -o yaml", namespace, centralCertName)
	log("  kubectl get secret -n %s %s -o jsonpath='{.data.tls\\.crt}' | base64 -d | openssl x509 -text -noout | grep -A2 'Subject Alternative Name'", namespace, centralSecretName)
	log("")
	log("To restore:")
	log("  %s -restore", os.Args[0])
	log("")
	log("To trigger the bug:")
	log("  %s -include-internal-sans", os.Args[0])

	return nil
}

func ensureNamespace(ctx context.Context, clientset *kubernetes.Clientset) error {
	log("Ensuring namespace %s exists...", namespace)

	_, err := clientset.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
	if err == nil {
		log("✓ Namespace already exists")
		return nil
	}

	if !apierrors.IsNotFound(err) {
		return errors.Wrap(err, "failed to check namespace")
	}

	ns := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: namespace,
		},
	}

	_, err = clientset.CoreV1().Namespaces().Create(ctx, ns, metav1.CreateOptions{})
	if err != nil {
		return errors.Wrap(err, "failed to create namespace")
	}

	log("✓ Namespace created")
	return nil
}

func createCertManagerResources(ctx context.Context, dynamicClient dynamic.Interface) error {
	log("Creating cert-manager resources...")

	// Create ClusterIssuer for self-signed CA
	if err := createSelfSignedIssuer(ctx, dynamicClient); err != nil {
		return err
	}

	// Create CA Certificate
	if err := createCACertificate(ctx, dynamicClient); err != nil {
		return err
	}

	// Create Central Certificate
	if err := createCentralCertificate(ctx, dynamicClient); err != nil {
		return err
	}

	log("✓ Cert-manager resources created")
	return nil
}

func createSelfSignedIssuer(ctx context.Context, dynamicClient dynamic.Interface) error {
	issuerGVR := schema.GroupVersionResource{
		Group:    "cert-manager.io",
		Version:  "v1",
		Resource: "clusterissuers",
	}

	issuer := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "cert-manager.io/v1",
			"kind":       "ClusterIssuer",
			"metadata": map[string]interface{}{
				"name": caIssuerName,
			},
			"spec": map[string]interface{}{
				"selfSigned": map[string]interface{}{},
			},
		},
	}

	_, err := dynamicClient.Resource(issuerGVR).Create(ctx, issuer, metav1.CreateOptions{})
	if err != nil && !apierrors.IsAlreadyExists(err) {
		return errors.Wrap(err, "failed to create self-signed issuer")
	}

	return nil
}

func createCACertificate(ctx context.Context, dynamicClient dynamic.Interface) error {
	certGVR := schema.GroupVersionResource{
		Group:    "cert-manager.io",
		Version:  "v1",
		Resource: "certificates",
	}

	cert := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "cert-manager.io/v1",
			"kind":       "Certificate",
			"metadata": map[string]interface{}{
				"name":      caCertName,
				"namespace": namespace,
			},
			"spec": map[string]interface{}{
				"isCA":       true,
				"commonName": "Custom CA for StackRox Reproducer",
				"secretName": caSecretName,
				"duration":   "87600h", // 10 years
				"privateKey": map[string]interface{}{
					"algorithm": "RSA",
					"size":      2048,
				},
				"issuerRef": map[string]interface{}{
					"name":  caIssuerName,
					"kind":  "ClusterIssuer",
					"group": "cert-manager.io",
				},
			},
		},
	}

	_, err := dynamicClient.Resource(certGVR).Namespace(namespace).Create(ctx, cert, metav1.CreateOptions{})
	if err != nil && !apierrors.IsAlreadyExists(err) {
		return errors.Wrap(err, "failed to create CA certificate")
	}

	return nil
}

func createCentralCertificate(ctx context.Context, dynamicClient dynamic.Interface) error {
	certGVR := schema.GroupVersionResource{
		Group:    "cert-manager.io",
		Version:  "v1",
		Resource: "certificates",
	}

	// First, create an Issuer (not ClusterIssuer) that uses the CA secret
	issuerGVR := schema.GroupVersionResource{
		Group:    "cert-manager.io",
		Version:  "v1",
		Resource: "issuers",
	}

	issuer := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "cert-manager.io/v1",
			"kind":       "Issuer",
			"metadata": map[string]interface{}{
				"name":      "custom-ca-issuer",
				"namespace": namespace,
			},
			"spec": map[string]interface{}{
				"ca": map[string]interface{}{
					"secretName": caSecretName,
				},
			},
		},
	}

	_, err := dynamicClient.Resource(issuerGVR).Namespace(namespace).Create(ctx, issuer, metav1.CreateOptions{})
	if err != nil && !apierrors.IsAlreadyExists(err) {
		return errors.Wrap(err, "failed to create CA issuer")
	}

	// Configure certificate SANs based on flag
	var dnsNames []interface{}
	var commonName string

	if includeInternalSANs {
		// Include internal service names - this triggers the bug!
		// When config-controller connects to central.stackrox.svc:443,
		// Central will serve this custom cert (because SNI matches),
		// and config-controller won't be able to verify it.
		commonName = fmt.Sprintf("central.%s.svc", namespace)
		dnsNames = []interface{}{
			"central",
			fmt.Sprintf("central.%s", namespace),
			fmt.Sprintf("central.%s.svc", namespace),
			fmt.Sprintf("central.%s.svc.cluster.local", namespace),
		}
	} else {
		// Only external names - Central will fallback to operator cert for internal connections
		// Config-controller connects to central.stackrox.svc, which doesn't match these SANs,
		// so Central serves the operator cert instead, and config-controller works.
		commonName = "central-external.example.com"
		dnsNames = []interface{}{
			"central-external.example.com",
			"*.central-external.example.com",
		}
	}

	cert := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "cert-manager.io/v1",
			"kind":       "Certificate",
			"metadata": map[string]interface{}{
				"name":      centralCertName,
				"namespace": namespace,
			},
			"spec": map[string]interface{}{
				"secretName": centralSecretName,
				"duration":   "87600h",
				"commonName": commonName,
				"dnsNames":   dnsNames,
				"privateKey": map[string]interface{}{
					"algorithm": "RSA",
					"size":      2048,
				},
				"usages": []interface{}{
					"server auth",
					"client auth",
					"digital signature",
					"key encipherment",
				},
				"issuerRef": map[string]interface{}{
					"name":  "custom-ca-issuer",
					"kind":  "Issuer",
					"group": "cert-manager.io",
				},
			},
		},
	}

	_, err = dynamicClient.Resource(certGVR).Namespace(namespace).Create(ctx, cert, metav1.CreateOptions{})
	if err != nil && !apierrors.IsAlreadyExists(err) {
		return errors.Wrap(err, "failed to create Central certificate")
	}

	return nil
}

func waitForCertificate(ctx context.Context, dynamicClient dynamic.Interface, certName string) error {
	log("Waiting for certificate %s to be ready...", certName)

	certGVR := schema.GroupVersionResource{
		Group:    "cert-manager.io",
		Version:  "v1",
		Resource: "certificates",
	}

	err := wait.PollUntilContextTimeout(ctx, 2*time.Second, 2*time.Minute, true, func(ctx context.Context) (bool, error) {
		cert, err := dynamicClient.Resource(certGVR).Namespace(namespace).Get(ctx, certName, metav1.GetOptions{})
		if err != nil {
			if apierrors.IsNotFound(err) {
				return false, nil
			}
			return false, err
		}

		conditions, found, err := unstructured.NestedSlice(cert.Object, "status", "conditions")
		if err != nil || !found {
			return false, nil
		}

		for _, cond := range conditions {
			condMap, ok := cond.(map[string]interface{})
			if !ok {
				continue
			}

			condType, _, _ := unstructured.NestedString(condMap, "type")
			status, _, _ := unstructured.NestedString(condMap, "status")

			if condType == "Ready" && status == "True" {
				return true, nil
			}
		}

		return false, nil
	})

	if err != nil {
		return errors.Wrapf(err, "certificate %s did not become ready", certName)
	}

	log("✓ Certificate %s is ready", certName)
	return nil
}

func getCACertContent(ctx context.Context, clientset *kubernetes.Clientset) (string, error) {
	log("Retrieving CA certificate content...")

	secret, err := clientset.CoreV1().Secrets(namespace).Get(ctx, caSecretName, metav1.GetOptions{})
	if err != nil {
		return "", errors.Wrap(err, "failed to get CA secret")
	}

	caCert, ok := secret.Data["ca.crt"]
	if !ok {
		return "", errors.New("ca.crt not found in CA secret")
	}

	log("✓ CA certificate retrieved")
	return string(caCert), nil
}

func createCentralCR(ctx context.Context, dynamicClient dynamic.Interface, caCert string) error {
	log("Creating Central CR...")

	// Use the typed Central API
	central := &platform.Central{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "platform.stackrox.io/v1alpha1",
			Kind:       "Central",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      centralCRName,
			Namespace: namespace,
		},
		Spec: platform.CentralSpec{
			Central: &platform.CentralComponentSpec{
				DefaultTLSSecret: &platform.LocalSecretReference{
					Name: centralSecretName,
				},
				DB: &platform.CentralDBSpec{
					IsEnabled: func() *platform.CentralDBEnabled { v := platform.CentralDBEnabledDefault; return &v }(),
				},
			},
			TLS: &platform.TLSConfig{
				AdditionalCAs: []platform.AdditionalCA{
					{
						Name:    "custom-ca.crt",
						Content: caCert,
					},
				},
			},
			// Egress: &platform.Egress{
			// 	ConnectivityPolicy: platform.ConnectivityOffline.Pointer(),
			// },
			Scanner: &platform.ScannerComponentSpec{
				ScannerComponent: func() *platform.ScannerComponentPolicy { v := platform.ScannerComponentDisabled; return &v }(),
			},
		},
	}

	// Convert typed object to unstructured for dynamic client
	unstructuredObj, err := runtime.DefaultUnstructuredConverter.ToUnstructured(central)
	if err != nil {
		return errors.Wrap(err, "failed to convert Central to unstructured")
	}

	unstructuredCentral := &unstructured.Unstructured{Object: unstructuredObj}

	centralGVR := schema.GroupVersionResource{
		Group:    "platform.stackrox.io",
		Version:  "v1alpha1",
		Resource: "centrals",
	}

	_, err = dynamicClient.Resource(centralGVR).Namespace(namespace).Create(ctx, unstructuredCentral, metav1.CreateOptions{})
	if err != nil {
		if apierrors.IsAlreadyExists(err) {
			log("✓ Central CR already exists")
			return nil
		}
		return errors.Wrap(err, "failed to create Central CR")
	}

	log("✓ Central CR created")
	return nil
}

func log(format string, args ...interface{}) {
	timestamp := time.Now().Format("2006-01-02 15:04:05")
	fmt.Printf("[%s] %s\n", timestamp, fmt.Sprintf(format, args...))
}
