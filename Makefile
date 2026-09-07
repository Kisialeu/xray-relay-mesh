.PHONY: check test golden

check:
	./scripts/check.sh

test:
	./tests/run.sh

golden:
	./tests/update-golden.sh examples/inventory.2node.json
	./tests/update-golden.sh examples/inventory.3node.json
