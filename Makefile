
# TL;DR:
# make build: build locally
# make test: run all tests
# make test-unit: just unit tests
# make test-e2e: just e2e tests
# make release: after git tag, release to github and prepare krew file
# make update-deps: bump all Go dependencies (k8s pins respected via K8S_VERSION)
# make vuln: run govulncheck

.PHONY: test test-unit test-e2e build goreleaser release clean update-deps vuln

os ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
arch ?= $(shell go env GOARCH | tr '[:upper:]' '[:lower:]')
underscore = $(word $2,$(subst _, ,$1))

# K8S_VERSION pins both the module version (v0.X.Y) and the
# k8s.io/kubernetes meta-module version (v1.X.Y). Override on the CLI:
#   make update-deps K8S_VERSION=0.36.1
K8S_VERSION ?= 0.36.1
K8S_KUBERNETES_VERSION ?= 1.$(word 2,$(subst ., ,$(K8S_VERSION))).$(word 3,$(subst ., ,$(K8S_VERSION)))

test: test-unit test-e2e test-integration

test-unit:
	go test -v ./...

test-e2e: dist/kubectl-neat_$(os)_$(arch)
	bats ./test/e2e-cli.bats

test-integration: dist/kubectl-neat_$(os)_$(arch).tar.gz dist/kubectl-neat_$(os)_$(arch)*/kubectl-neat dist/checksums.txt
	bats ./test/e2e-kubectl.bats
	bats ./test/e2e-krew.bats

build: dist/kubectl-neat_$(os)_$(arch)

SRC = $(shell find . -type f -name '*.go' -not -path "./vendor/*")
dist/kubectl-neat_%: $(SRC)
	GOOS=$(call underscore,$*,1) GOARCH=$(call underscore,$*,2) go build -o dist/$(@F)

# release by default will not publish. run with `publish=1` to publish
goreleaserflags = --skip=publish --snapshot
ifdef publish
	goreleaserflags =
endif
# relase always re-builds (no dependencies on purpose)
goreleaser: $(SRC)
	goreleaser --clean $(goreleaserflags) 

dist/kubectl-neat_darwin_arm64.tar.gz dist/kubectl-neat_darwin_amd64.tar.gz dist/kubectl-neat_linux_arm64.tar.gz dist/kubectl-neat_linux_amd64.tar.gz dist/checksums.txt: goreleaser
	# no op recipe
	@:

release: publish = 1
release: dist/kubectl-neat_darwin_arm64.tar.gz dist/kubectl-neat_darwin_amd64.tar.gz dist/kubectl-neat_linux_arm64.tar.gz dist/kubectl-neat_linux_amd64.tar.gz dist/checksums.txt
	./krew-package.sh 'darwin' 'arm64' 'neat' './dist'
	./krew-package.sh 'darwin' 'amd64' 'neat' './dist'
	./krew-package.sh 'linux' 'arm64' 'neat' './dist'
	./krew-package.sh 'linux' 'amd64' 'neat' './dist'
	# merge
	yq -o json "dist/kubectl-neat_darwin_amd64.yaml" > dist/darwin-amd64.json
	yq -o json "dist/kubectl-neat_darwin_arm64.yaml" > dist/darwin-arm64.json
	yq -o json "dist/kubectl-neat_linux_amd64.yaml" > dist/linux-amd64.json
	yq -o json "dist/kubectl-neat_linux_arm64.yaml" > dist/linux-arm64.json

	rm dist/kubectl-neat_darwin_arm64.yaml dist/kubectl-neat_darwin_amd64.yaml dist/kubectl-neat_linux_arm64.yaml dist/kubectl-neat_linux_amd64.yaml
	jq --slurp '.[0].spec.platforms += .[1].spec.platforms | .[0]' 'dist/darwin-amd64.json' 'dist/darwin-arm64.json' > 'dist/darwin.json'
	jq --slurp '.[0].spec.platforms += .[1].spec.platforms | .[0]' 'dist/linux-amd64.json' 'dist/linux-arm64.json' > 'dist/linux.json'
	jq --slurp '.[0].spec.platforms += .[1].spec.platforms | .[0]' 'dist/linux.json' 'dist/darwin.json' > 'dist/kubectl-neat.json'
	yq -o yaml --prettyPrint dist/kubectl-neat.json > dist/kubectl-neat.yaml
	rm dist/kubectl-neat.json dist/darwin.json dist/linux.json dist/darwin-amd64.json dist/darwin-arm64.json dist/linux-amd64.json dist/linux-arm64.json

clean:
	rm -rf dist

# update-deps bumps all Go module dependencies.
# Strategy:
#   1. Rewrite every `replace k8s.io/<x> => k8s.io/<x> v0.A.B` line to K8S_VERSION
#      (go get -u does NOT touch the right-hand side of replace directives).
#   2. Pin the direct k8s.io deps explicitly.
#   3. Bump everything else (-u) and tidy.
# Override the target version with: make update-deps K8S_VERSION=0.35.5
update-deps:
	@echo ">> Bumping k8s replace directives to v$(K8S_VERSION)"
	@sed -i.bak -E 's#(k8s\.io/[a-z0-9-]+ v)0\.[0-9]+\.[0-9]+$$#\1$(K8S_VERSION)#g' go.mod && rm go.mod.bak
	@echo ">> Pinning direct k8s deps"
	go get k8s.io/apimachinery@v$(K8S_VERSION) k8s.io/client-go@v$(K8S_VERSION) k8s.io/kubernetes@v$(K8S_KUBERNETES_VERSION)
	@echo ">> Upgrading remaining dependencies"
	go get -u ./...
	@echo ">> Re-pinning k8s replace directives (go get -u may have drifted indirects)"
	@sed -i.bak -E 's#(k8s\.io/[a-z0-9-]+ v)0\.[0-9]+\.[0-9]+$$#\1$(K8S_VERSION)#g' go.mod && rm go.mod.bak
	go get k8s.io/apimachinery@v$(K8S_VERSION) k8s.io/client-go@v$(K8S_VERSION) k8s.io/kubernetes@v$(K8S_KUBERNETES_VERSION)
	@echo ">> go mod tidy"
	go mod tidy
	@echo ">> Verifying build"
	go build ./...
	@echo ">> Running tests"
	go test ./...
	@echo ">> Done. Review go.mod / go.sum changes before committing."

vuln:
	@command -v govulncheck >/dev/null 2>&1 || go install golang.org/x/vuln/cmd/govulncheck@latest
	govulncheck ./...
