.PHONY: all build run restore clean deps help

# Default target
all: build

# Build the reproducer
build:
	@echo "Building config-controller-reproducer..."
	go build -o bin/reproducer .

# Run the reproducer
run: build
	@echo "Running reproducer..."
	./bin/reproducer

# Restore (delete Central CR)
restore: build
	@echo "Restoring environment..."
	./bin/reproducer -restore

# Download dependencies
deps:
	@echo "Downloading dependencies..."
	go mod download
	go mod tidy

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf bin/

# Display help
help:
	@echo "Config-Controller Crash Reproducer"
	@echo ""
	@echo "Available targets:"
	@echo "  make build    - Build the reproducer binary"
	@echo "  make run      - Build and run the reproducer"
	@echo "  make restore  - Restore environment by deleting Central CR"
	@echo "  make deps     - Download and tidy Go dependencies"
	@echo "  make clean    - Remove build artifacts"
	@echo "  make help     - Display this help message"
	@echo ""
	@echo "Manual usage:"
	@echo "  ./bin/reproducer                           - Run reproducer (external SANs only)"
	@echo "  ./bin/reproducer -include-internal-sans    - Run reproducer with internal SANs (triggers bug)"
	@echo "  ./bin/reproducer -restore                  - Restore environment"
	@echo "  ./bin/reproducer -kubeconfig PATH          - Use specific kubeconfig"
	@echo ""
	@echo "Understanding the bug:"
	@echo "  Without -include-internal-sans: Certificate has external SANs only"
	@echo "    → Central serves operator cert (SNI doesn't match custom cert)"
	@echo "    → Config-controller works (can verify operator cert)"
	@echo ""
	@echo "  With -include-internal-sans: Certificate includes central.stackrox.svc"
	@echo "    → Central serves custom cert (SNI matches)"
	@echo "    → Config-controller crashes (cannot verify custom cert)"
