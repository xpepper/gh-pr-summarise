.PHONY: test shellcheck bats install-deps-macos install-deps-ubuntu

test: shellcheck bats

shellcheck:
	shellcheck gh-pr-summarise

bats:
	bats tests/

install-deps-macos:
	brew install shellcheck bats-core

install-deps-ubuntu:
	sudo apt-get install -y shellcheck
	npm install -g bats
