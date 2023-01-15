.PHONY: all format lint fix

all: format lint

_FILES = $(shell find . -maxdepth 1 -executable -type f)

lint:
			@echo "Running shellcheck"
			shellcheck --shell=bash --enable=all $(_FILES)

format:
			@echo "shfmt check"
			shfmt -d $(_FILES)

fix:
			@echo "Formatting with shfmt"
			shfmt -w $(_FILES)
