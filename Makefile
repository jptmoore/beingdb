.PHONY: build run clean test install setup-test-data integration-test

build:
	dune build

run:
	dune exec bin/main.exe -- --sync

run-dev:
	dune exec bin/main.exe -- --sync --port 8080

clean:
	dune clean
	rm -rf data/

install:
	opam install . --deps-only

watch:
	dune build --watch

setup-test-data:
	chmod +x test/setup_test_data.sh
	./test/setup_test_data.sh

test:
	dune test

integration-test:
	chmod +x test/integration_test.sh
	./test/integration_test.sh

test-all:
	chmod +x test/run_all_tests.sh
	./test/run_all_tests.sh
