.PHONY: test test-unit test-integration clean help

# Tests
test-unit:
	dune runtest

test-integration:
	@echo "Ensuring clean state..."
	@rm -rf git-store pack-store examples/data
	bash test/docker_test.sh

test: test-integration

clean:
	docker compose down -v
	rm -rf git-store pack-store examples/data _build

help:
	@echo "BeingDB Makefile:"
	@echo "  test             - Run integration tests"
	@echo "  test-unit        - Run OCaml unit tests"
	@echo "  test-integration - Run API integration tests"
	@echo "  clean            - Clean everything"
