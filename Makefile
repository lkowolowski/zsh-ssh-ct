# Makefile — local linting and validation helpers
# Usage:
#   make lint          run all linters
#   make shellcheck    shellcheck on all .zsh files
#   make zsh-check     zsh -n syntax check on all .zsh files
#   make yamllint      yamllint on all .yml files
#   make markdownlint  markdownlint on all .md files
#   make pre-commit    run all pre-commit hooks against every file

ZSH_FILES    := $(shell find . -name '*.zsh' -not -path './.git/*')
YAML_FILES   := $(shell find . -name '*.yml' -not -name '.pre-commit-config.yaml' -not -path './.git/*')
MD_FILES     := $(shell find . -name '*.md' -not -path './.git/*')

.PHONY: all lint shellcheck zsh-check yamllint markdownlint checkmake pre-commit clean test

all: lint

clean:
	@echo "Nothing to clean."

test:
	@$(MAKE) lint

lint: shellcheck zsh-check yamllint markdownlint checkmake
	@echo ""
	@echo "✓ All checks passed."

shellcheck:
	@echo "→ shellcheck"
	@shellcheck --severity=warning --color=always $(ZSH_FILES)

zsh-check:
	@echo "→ zsh -n (syntax check)"
	@for f in $(ZSH_FILES); do \
		zsh -n "$$f" && echo "  ok  $$f" || exit 1; \
	done

yamllint:
	@echo "→ yamllint"
	@yamllint -c .yamllint.yml $(YAML_FILES)

markdownlint:
	@echo "→ markdownlint"
	@markdownlint --config .markdownlint.yml $(MD_FILES)

checkmake:
	@echo "→ checkmake"
	@checkmake --config .checkmake.ini Makefile

pre-commit:
	@echo "→ pre-commit (all files)"
	@pre-commit run --all-files
