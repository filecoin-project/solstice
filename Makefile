SUBMODULES := $(patsubst %/,%,$(dir $(wildcard lib/*/[Mm]akefile lib/*/GNUmakefile)))
SUBMODULE_BUILD := $(addsuffix /build,$(SUBMODULES))
SUBMODULE_CLEAN := $(addsuffix /clean,$(SUBMODULES))
SUBMODULE_TEST := $(addsuffix /test,$(SUBMODULES))
SUBMODULE_PHONY := $(SUBMODULE_BUILD) $(SUBMODULE_CLEAN) $(SUBMODULE_TEST)

.PHONY: build clean default test $(SUBMODULE_BUILD) $(SUBMODULE_CLEAN) $(SUBMODULE_TEST)

default: build

$(SUBMODULE_PHONY):
	$(MAKE) -C $(dir $@) $(notdir $@)

build: $(SUBMODULE_BUILD)
	forge build

test: build $(SUBMODULE_TEST)
	forge test

clean: $(SUBMODULE_CLEAN)
	rm -rf out
