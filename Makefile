.PHONY: install update format lint test

install:
	BEADS_DIR=$$(pwd)/.beads shards install

update:
	BEADS_DIR=$$(pwd)/.beads shards update

format:
	crystal tool format --check

EXE_SUFFIX =
ifeq ($(OS),Windows_NT)
EXE_SUFFIX = .exe
endif
AMEBAR = ./bin/ameba$(EXE_SUFFIX)
lint:
	$(AMEBAR) --fix
	$(AMEBAR) --format progress

test:
	crystal spec

clean:
	rm -rf ./temp/*
