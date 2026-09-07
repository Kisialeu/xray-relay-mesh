.PHONY: check test golden

check:
	./bashbuild/scripts/check.sh

test:
	./tests/run.sh

golden:
	./tests/update-golden.sh configs/examples/inventory.2node.json
	./tests/update-golden.sh configs/examples/inventory.3node.json
