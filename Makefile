VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -X main.version=$(VERSION)

.PHONY: all build test vet fmt check install uninstall clean

all: check build

build:
	go build -ldflags '$(LDFLAGS)' -o mousetime .

test:
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -l -w .

check: vet test
	@test -z "$$(gofmt -l .)" || { echo "gofmt needed:"; gofmt -l .; exit 1; }

# Installs the launchd agent that keeps the dock clock synced.
install:
	./launchd/install.sh

uninstall:
	./launchd/install.sh uninstall

clean:
	rm -f mousetime
