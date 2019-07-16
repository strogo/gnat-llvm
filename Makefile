all: build-with-opt

.PHONY: acats

sanity-check:
	@if ! [ -d llvm-interface/gnat_src ]; then \
          echo "error: directory llvm-interface/gnat_src not found"; exit 1; \
	fi

build: sanity-check build-be

build-opt: sanity-check build-be-opt

build-with-opt: sanity-check build-be-with-opt

build-be:
	$(MAKE) -C llvm-interface build

build-be-opt:
	$(MAKE) -C llvm-interface build-opt

build-be-with-opt:
	$(MAKE) -C llvm-interface build-with-opt

automated:
	$(MAKE) -C llvm-interface build-opt
	$(MAKE) -C llvm-interface gnatlib-automated

llvm:
	$(MAKE) -C llvm

acats:
	$(MAKE) -C acats

fixed-bugs:
	$(MAKE) -C fixedbugs

clean:
	$(MAKE) -C llvm-interface clean

.PHONY: llvm
