SHELL    := /bin/bash
SKILLS   := $(HOME)/.claude/skills
AGENTS   := $(HOME)/.claude/agents
PLUGINS  := review git data writing meta

.PHONY: install $(PLUGINS:%=install-%) smoke help

help:
	@printf 'Targets:\n'
	@printf '  install            Sync all plugins to ~/.claude/\n'
	@printf '  install-<plugin>   Sync one plugin (review, git, data, writing, meta)\n'
	@printf '  smoke              Run all lib/smoke.sh scripts found in the repo\n'

install: $(PLUGINS:%=install-%)

define install_plugin
install-$(1):
	@mkdir -p $$(SKILLS)
	@rsync -a $(1)/skills/ $$(SKILLS)/
	@if [ -d $(1)/agents ]; then \
		mkdir -p $$(AGENTS); \
		rsync -a $(1)/agents/ $$(AGENTS)/; \
	fi
	@printf '[install] $(1) synced to ~/.claude/\n'
endef

$(foreach p,$(PLUGINS),$(eval $(call install_plugin,$(p))))

smoke:
	@find . -path '*/lib/smoke.sh' | sort | while read -r s; do \
		printf '\n=== %s ===\n' "$$s"; \
		bash "$$s" || exit 1; \
	done
