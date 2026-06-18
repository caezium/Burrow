# Mole Windows - Makefile
# Build Go tools for Windows

.PHONY: all build clean analyze status

# Default target
all: build

# Build both tools
build: analyze status

# Build analyze tool
analyze:
	@echo "Building analyze..."
	@go build -o bin/analyze.exe ./cmd/analyze/

# Build status tool
status:
	@echo "Building status..."
	@go build -o bin/status.exe ./cmd/status/

# Clean build artifacts
clean:
	@echo "Cleaning..."
	@rm -f bin/analyze.exe bin/status.exe

# Install (copy to PATH)
install: build
	@echo "Installing to $(USERPROFILE)/bin..."
	@mkdir -p "$(USERPROFILE)/bin"
	@cp bin/analyze.exe "$(USERPROFILE)/bin/"
	@cp bin/status.exe "$(USERPROFILE)/bin/"

# Run tests
test:
	@go test -v ./...

# Format code
fmt:
	@go fmt ./...

# Vet code
vet:
	@go vet ./...
