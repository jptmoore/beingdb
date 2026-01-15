.PHONY: test test-unit clean help

# Tests
test-unit:
	dune runtest

test: test-unit

clean:
	rm -rf git-store pack-store examples/data _build

help:
	@echo "BeingDB Makefile:"
	@echo "  test       - Run unit tests"
	@echo "  test-unit  - Run OCaml unit tests"
	@echo "  clean      - Clean build artifacts and test data"
