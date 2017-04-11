.PHONY: all binary calico/node test clean help
default: help
all: test                                               ## Run all the tests
test: st test-containerized node-test-containerized     ## Run all the tests
all: dist/calicoctl dist/calicoctl-darwin-amd64 dist/calicoctl-windows-amd64.exe test-containerized node-test-containerized

# Include the build file for calico/node (This also pulls in Makefile.calicoctl)
include Makefile.calico-node


# This depends on clean to ensure that dependent images get untagged and repulled
.PHONY: semaphore
semaphore: clean
	# Clean up unwanted files to free disk space.
	bash -c 'rm -rf /home/runner/{.npm,.phpbrew,.phpunit,.kerl,.kiex,.lein,.nvm,.npm,.phpbrew,.rbenv}'

	# Run the containerized UTs first.
	$(MAKE) test-containerized
	$(MAKE) node-test-containerized

	# Actually run the tests (refreshing the images as required), we only run a
	# small subset of the tests for testing SSL support.  These tests are run
	# using "latest" tagged images.
	$(MAKE) calico/ctl calico/node st
	ST_TO_RUN=tests/st/policy $(MAKE) st-ssl

	# Make sure that calicoctl builds cross-platform.
	$(MAKE) dist/calicoctl-darwin-amd64 dist/calicoctl-windows-amd64.exe

	# Assumes that a few environment variables exist - BRANCH_NAME PULL_REQUEST_NUMBER
	# If this isn't a PR, then push :BRANCHNAME tagged and :CALICOCONTAINERS_VERSION
	# tagged images to Dockerhub and quay for both calico/node and calico/ctl.  This
	# requires a rebuild of calico/ctl in both cases.
	set -e; \
	if [ -z $$PULL_REQUEST_NUMBER ]; then \
		rm dist/calicoctl ;\
		CALICOCTL_NODE_VERSION=$$BRANCHNAME $(MAKE) calico/ctl ;\
		docker tag $(NODE_CONTAINER_NAME) quay.io/$(NODE_CONTAINER_NAME):$$BRANCH_NAME && \
		docker push quay.io/$(NODE_CONTAINER_NAME):$$BRANCH_NAME; \
		docker tag $(NODE_CONTAINER_NAME) $(NODE_CONTAINER_NAME):$$BRANCH_NAME && \
		docker push $(NODE_CONTAINER_NAME):$$BRANCH_NAME; \
		docker tag $(CTL_CONTAINER_NAME) quay.io/$(CTL_CONTAINER_NAME):$$BRANCH_NAME && \
		docker push quay.io/$(CTL_CONTAINER_NAME):$$BRANCH_NAME; \
		docker tag $(CTL_CONTAINER_NAME) $(CTL_CONTAINER_NAME):$$BRANCH_NAME && \
		docker push $(CTL_CONTAINER_NAME):$$BRANCH_NAME; \
		rm dist/calicoctl ;\
		CALICOCTL_NODE_VERSION=$(CALICOCONTAINERS_VERSION) $(MAKE) calico/ctl ;\
		docker tag $(NODE_CONTAINER_NAME) quay.io/$(NODE_CONTAINER_NAME):$(CALICOCONTAINERS_VERSION) && \
		docker push quay.io/$(NODE_CONTAINER_NAME):$(CALICOCONTAINERS_VERSION); \
		docker tag $(NODE_CONTAINER_NAME) $(NODE_CONTAINER_NAME):$(CALICOCONTAINERS_VERSION) && \
		docker push $(NODE_CONTAINER_NAME):$(CALICOCONTAINERS_VERSION); \
		docker tag $(CTL_CONTAINER_NAME) quay.io/$(CTL_CONTAINER_NAME):$(CALICOCONTAINERS_VERSION) && \
		docker push quay.io/$(CTL_CONTAINER_NAME):$(CALICOCONTAINERS_VERSION); \
		docker tag $(CTL_CONTAINER_NAME) $(CTL_CONTAINER_NAME):$(CALICOCONTAINERS_VERSION) && \
		docker push $(CTL_CONTAINER_NAME):$(CALICOCONTAINERS_VERSION); \
	fi

###############################################################################
# calicoctl UTs
###############################################################################
.PHONY: ut
## Run the Unit Tests locally
ut: dist/calicoctl
	# Run tests in random order find tests recursively (-r).
	ginkgo -cover -r --skipPackage vendor

	@echo
	@echo '+==============+'
	@echo '| All coverage |'
	@echo '+==============+'
	@echo
	@find . -iname '*.coverprofile' | xargs -I _ go tool cover -func=_

	@echo
	@echo '+==================+'
	@echo '| Missing coverage |'
	@echo '+==================+'
	@echo
	@find . -iname '*.coverprofile' | xargs -I _ go tool cover -func=_ | grep -v '100.0%'

PHONY: test-containerized
## Run the tests in a container. Useful for CI, Mac dev.
test-containerized: dist/calicoctl calicoctl_test_container.created
	docker run --rm -v ${PWD}:/go/src/github.com/projectcalico/calicoctl:rw \
	$(TEST_CALICOCTL_CONTAINER_NAME) bash -c 'make ut'

###############################################################################
# calicoctl build
# - Building the calicoctl binary in a container
# - Building the calicoctl binary outside a container ("simple-binary")
# - Building the calico/ctl image
###############################################################################
CALICOCTL_DIR=calicoctl
CTL_CONTAINER_NAME?=calico/ctl
CALICOCTL_FILES=$(shell find $(CALICOCTL_DIR) -name '*.go')
CTL_CONTAINER_CREATED=$(CALICOCTL_DIR)/.calico_ctl.created

CALICOCTL_NODE_VERSION?="latest"
CALICOCTL_BUILD_DATE?=$(shell date -u +'%FT%T%z')
CALICOCTL_GIT_REVISION?=$(shell git rev-parse --short HEAD)

LDFLAGS=-ldflags "-X github.com/projectcalico/calicoctl/calicoctl/commands.VERSION=$(CALICOCONTAINERS_VERSION) \
	-X github.com/projectcalico/calicoctl/calicoctl/commands/node.VERSION=$(CALICOCTL_NODE_VERSION) \
	-X github.com/projectcalico/calicoctl/calicoctl/commands.BUILD_DATE=$(CALICOCTL_BUILD_DATE) \
	-X github.com/projectcalico/calicoctl/calicoctl/commands.GIT_REVISION=$(CALICOCTL_GIT_REVISION) -s -w"

GLIDE_CONTAINER_NAME?=glide-ppc64le
TEST_CALICOCTL_CONTAINER_NAME=calico/calicoctl_test_container
TEST_CALICOCTL_CONTAINER_MARKER=calicoctl_test_container.created

LIBCALICOGO_PATH?=none

calico/ctl: $(CTL_CONTAINER_CREATED)      ## Create the calico/ctl image

## Use this to populate the vendor directory after checking out the repository.
## To update upstream dependencies, delete the glide.lock file first.
glide-image: 
	docker build -t glide-ppc64le - < calicoctl/Dockerfile.glide

vendor: glide.lock
	# To build without Docker just run "glide install -strip-vendor"
	if [ "$(LIBCALICOGO_PATH)" != "none" ]; then \
          EXTRA_DOCKER_BIND="-v $(LIBCALICOGO_PATH):/go/src/github.com/projectcalico/libcalico-go:ro"; \
	fi; \
	docker run --rm \
		-v ${PWD}:/go/src/github.com/projectcalico/calicoctl:rw $$EXTRA_DOCKER_BIND \
      --entrypoint /bin/sh $(GLIDE_CONTAINER_NAME) -e -c ' \
        cd /go/src/github.com/projectcalico/calicoctl && \
        glide install -strip-vendor && \
        chown $(shell id -u):$(shell id -u) -R vendor'

$(TEST_CALICOCTL_CONTAINER_MARKER): calicoctl/Dockerfile.calicoctl.build
	docker build -f calicoctl/Dockerfile.calicoctl.build -t $(TEST_CALICOCTL_CONTAINER_NAME) .
	touch $@

# build calico_ctl image
$(CTL_CONTAINER_CREATED): calicoctl/Dockerfile.calicoctl dist/calicoctl
	docker build -t $(CTL_CONTAINER_NAME) -f calicoctl/Dockerfile.calicoctl .
	touch $@

## Build startup.go
startup:
	GOOS=linux GOARCH=ppc64le CGO_ENABLED=0 go build -v -o dist/startup $(LDFLAGS) "./calico_node/startup/startup.go"

dist/startup: $(STARTUP_FILES) vendor
	mkdir -p dist
	docker run --rm \
	  -v ${PWD}:/go/src/github.com/projectcalico/calicoctl:ro \
	  -v ${PWD}/dist:/go/src/github.com/projectcalico/calicoctl/dist \
	  ppc64le/golang:1.7.3 bash -c '\
	    cd /go/src/github.com/projectcalico/calicoctl && \
	    make startup && \
	    chown -R $(shell id -u):$(shell id -u) dist'

## Build allocate_ipip_addr.go
allocate-ipip-addr:
	GOOS=linux GOARCH=ppc64le CGO_ENABLED=0 go build -v -o dist/allocate-ipip-addr $(LDFLAGS) "./calico_node/allocateipip/allocate_ipip_addr.go"

dist/allocate-ipip-addr: $(ALLOCATE_IPIP_FILES) vendor
	mkdir -p dist
	docker run --rm \
	  -v ${PWD}:/go/src/github.com/projectcalico/calicoctl:ro \
	  -v ${PWD}/dist:/go/src/github.com/projectcalico/calicoctl/dist \
	  ppc64le/golang:1.7.3 bash -c '\
	    cd /go/src/github.com/projectcalico/calicoctl && \
	    make allocate-ipip-addr && \
	    chown -R $(shell id -u):$(shell id -u) dist'

## Build calicoctl
binary: $(CALICOCTL_FILES) vendor
	GOOS=$(OS) GOARCH=ppc64le CGO_ENABLED=0 go build -v -o dist/calicoctl-$(OS)-$(ARCH) $(LDFLAGS) "./calicoctl/calicoctl.go"

dist/calicoctl: $(CALICOCTL_FILES) vendor
	$(MAKE) dist/calicoctl-linux-ppc64le
	mv dist/calicoctl-linux-ppc64le dist/calicoctl

dist/calicoctl-linux-ppc64le: $(CALICOCTL_FILES) vendor
	$(MAKE) OS=linux ARCH=ppc64le binary-containerized

dist/calicoctl-darwin-amd64: $(CALICOCTL_FILES) vendor
	$(MAKE) OS=darwin ARCH=amd64 binary-containerized

dist/calicoctl-windows-amd64.exe: $(CALICOCTL_FILES) vendor
	$(MAKE) OS=windows ARCH=amd64 binary-containerized
	mv dist/calicoctl-windows-amd64 dist/calicoctl-windows-amd64.exe

## Run the build in a container. Useful for CI
binary-containerized: $(CALICOCTL_FILES) vendor
	mkdir -p dist
	docker run --rm \
	  -e OS=$(OS) -e ARCH=$(ARCH) \
	  -e CALICOCONTAINERS_VERSION=$(CALICOCONTAINERS_VERSION) -e CALICOCTL_NODE_VERSION=$(CALICOCTL_NODE_VERSION) \
	  -e CALICOCTL_BUILD_DATE=$(CALICOCTL_BUILD_DATE) -e CALICOCTL_GIT_REVISION=$(CALICOCTL_GIT_REVISION) \
	  -v ${PWD}:/go/src/github.com/projectcalico/calicoctl:ro \
	  -v ${PWD}/dist:/go/src/github.com/projectcalico/calicoctl/dist \
	  ppc64le/golang:1.7.3 bash -c '\
	    cd /go/src/github.com/projectcalico/calicoctl && \
	    make OS=$(OS) ARCH=$(ARCH) \
	         CALICOCONTAINERS_VERSION=$(CALICOCONTAINERS_VERSION) CALICOCTL_NODE_VERSION=$(CALICOCTL_NODE_VERSION) \
	         CALICOCTL_BUILD_DATE=$(CALICOCTL_BUILD_DATE) CALICOCTL_GIT_REVISION=$(CALICOCTL_GIT_REVISION) \
	         binary && \
	      chown -R $(shell id -u):$(shell id -u) dist'

## Etcd is used by the tests
.PHONY: run-etcd
run-etcd:
	@-docker rm -f calico-etcd
	docker run --detach \
	-p 2379:2379 \
	--name calico-etcd quay.io/coreos/etcd \
	etcd \
	--advertise-client-urls "http://$(LOCAL_IP_ENV):2379,http://127.0.0.1:2379,http://$(LOCAL_IP_ENV):4001,http://127.0.0.1:4001" \
	--listen-client-urls "http://0.0.0.0:2379,http://0.0.0.0:4001"

## Etcd is used by the STs
.PHONY: run-etcd-host
run-etcd-host:
	@-docker rm -f calico-etcd
	docker run --detach \
	--net=host \
	--name calico-etcd quay.io/coreos/etcd \
	etcd \
	--advertise-client-urls "http://$(LOCAL_IP_ENV):2379,http://127.0.0.1:2379,http://$(LOCAL_IP_ENV):4001,http://127.0.0.1:4001" \
	--listen-client-urls "http://0.0.0.0:2379,http://0.0.0.0:4001"

## Install or update the tools used by the build
.PHONY: update-tools
update-tools:
	go get -u github.com/Masterminds/glide
	go get -u github.com/kisielk/errcheck
	go get -u golang.org/x/tools/cmd/goimports
	go get -u github.com/golang/lint/golint
	go get -u github.com/onsi/ginkgo/ginkgo

## Perform static checks on the code. The golint checks are allowed to fail, the others must pass.
.PHONY: static-checks
static-checks: vendor
	# Format the code and clean up imports
	goimports -w $(CALICOCTL_FILES)

	# Check for coding mistake and missing error handling
	go vet -x $(glide nv)
	errcheck ./calicoctl

	# Check code style
	-golint $(CALICOCTL_FILES)

.PHONY: install
install:
	CGO_ENABLED=0 go install github.com/projectcalico/calicoctl/calicoctl

=======
>>>>>>> f0a54318e8776b413b8caf0543c17c61605d6a82
release: clean
ifndef VERSION
	$(error VERSION is undefined - run using make release VERSION=vX.Y.Z)
endif
	git tag $(VERSION)

	# Check to make sure the tag isn't "-dirty".
	if git describe --tags --dirty | grep dirty; \
	then echo current git working tree is "dirty". Make sure you do not have any uncommitted changes ;false; fi

	# Build the calicoctl binaries, as well as the calico/ctl and calico/node images.
	CALICOCTL_NODE_VERSION=$(VERSION) $(MAKE) dist/calicoctl dist/calicoctl-darwin-amd64 dist/calicoctl-windows-amd64.exe 
	CALICOCTL_NODE_VERSION=$(VERSION) $(MAKE) calico/ctl calico/node

	# Check that the version output includes the version specified.
	# Tests that the "git tag" makes it into the binaries. Main point is to catch "-dirty" builds
	# Release is currently supported on darwin / linux only.
	if ! docker run $(CTL_CONTAINER_NAME) version | grep 'Version:\s*$(VERSION)$$'; then \
	  echo "Reported version:" `docker run $(CTL_CONTAINER_NAME) version` "\nExpected version: $(VERSION)"; \
	  false; \
	else \
	  echo "Version check passed\n"; \
	fi

	# Retag images with corect version and quay
	docker tag $(NODE_CONTAINER_NAME) $(NODE_CONTAINER_NAME):$(VERSION)
	docker tag $(CTL_CONTAINER_NAME) $(CTL_CONTAINER_NAME):$(VERSION)
	docker tag $(NODE_CONTAINER_NAME) quay.io/$(NODE_CONTAINER_NAME):$(VERSION)
	docker tag $(CTL_CONTAINER_NAME) quay.io/$(CTL_CONTAINER_NAME):$(VERSION)
	docker tag $(NODE_CONTAINER_NAME) quay.io/$(NODE_CONTAINER_NAME):latest
	docker tag $(CTL_CONTAINER_NAME) quay.io/$(CTL_CONTAINER_NAME):latest

	# Check that images were created recently and that the IDs of the versioned and latest images match
	@docker images --format "{{.CreatedAt}}\tID:{{.ID}}\t{{.Repository}}:{{.Tag}}" $(NODE_CONTAINER_NAME)
	@docker images --format "{{.CreatedAt}}\tID:{{.ID}}\t{{.Repository}}:{{.Tag}}" $(NODE_CONTAINER_NAME):$(VERSION)
	@docker images --format "{{.CreatedAt}}\tID:{{.ID}}\t{{.Repository}}:{{.Tag}}" $(CTL_CONTAINER_NAME)
	@docker images --format "{{.CreatedAt}}\tID:{{.ID}}\t{{.Repository}}:{{.Tag}}" $(CTL_CONTAINER_NAME):$(VERSION)

	# Check that the images container the right sub-components
	docker run $(NODE_CONTAINER_NAME) calico-felix --version
	docker run $(NODE_CONTAINER_NAME) libnetwork-plugin -v

	@echo "\nNow push the tag and images. Then create a release on Github and"
	@echo "attach dist/calicoctl, dist/calicoctl-darwin-amd64, and dist/calicoctl-windows-amd64.exe binaries"
	@echo "\nAdd release notes for calicoctl and calico/node. Use this command"
	@echo "to find commit messages for this release: git log --oneline <old_release_version>...$(VERSION)"
	@echo "\nRelease notes for sub-components can be found at"
	@echo "https://github.com/projectcalico/<component_name>/releases/tag/<version>"
	@echo "\nAdd release notes from the following sub-component version releases:"
	@echo "\nfelix:$(FELIX_VER)"
	@echo "\nlibnetwork-plugin:$(LIBNETWORK_PLUGIN_VER)"
	@echo "\nlibcalico-go:$(LIBCALICOGO_VER)"
	@echo "\ncalico-bgp-daemon:$(GOBGPD_VER)"
	@echo "\ncalico-bird:$(BIRD_VER)"
	@echo "\nconfd:$(CONFD_VER)"
	@echo "git push origin $(VERSION)"
	@echo "docker push calico/ctl:$(VERSION)"
	@echo "docker push quay.io/calico/ctl:$(VERSION)"
	@echo "docker push calico/node:$(VERSION)"
	@echo "docker push quay.io/calico/node:$(VERSION)"
	@echo "docker push calico/ctl:latest"
	@echo "docker push quay.io/calico/ctl:latest"
	@echo "docker push calico/node:latest"
	@echo "docker push quay.io/calico/node:latest"
	@echo "See RELEASING.md for detailed instructions."

## Clean enough that a new release build will be clean
clean: clean-calicoctl
	find . -name '*.created' -exec rm -f {} +
	find . -name '*.pyc' -exec rm -f {} +
	rm -rf dist build certs *.tar vendor $(NODE_CONTAINER_DIR)/filesystem/bin

	# Delete images that we built in this repo
	docker rmi $(NODE_CONTAINER_NAME):latest || true

	# Retag and remove external images so that they will be pulled again
	# We avoid just deleting the image. We didn't build them here so it would be impolite to delete it.
	docker tag $(FELIX_CONTAINER_NAME) $(FELIX_CONTAINER_NAME)-backup && docker rmi $(FELIX_CONTAINER_NAME) || true
	docker tag $(SYSTEMTEST_CONTAINER) $(SYSTEMTEST_CONTAINER)-backup && docker rmi $(SYSTEMTEST_CONTAINER) || true

.PHONY: help
## Display this help text
help: # Some kind of magic from https://gist.github.com/rcmachado/af3db315e31383502660
	$(info Available targets)
	@awk '/^[a-zA-Z\-\_0-9\/]+:/ {                                      \
		nb = sub( /^## /, "", helpMsg );                                \
		if(nb == 0) {                                                   \
			helpMsg = $$0;                                              \
			nb = sub( /^[^:]*:.* ## /, "", helpMsg );                   \
		}                                                               \
		if (nb)                                                         \
			printf "\033[1;31m%-" width "s\033[0m %s\n", $$1, helpMsg;  \
	}                                                                   \
	{ helpMsg = $$0 }'                                                  \
	width=20                                                            \
	$(MAKEFILE_LIST)
