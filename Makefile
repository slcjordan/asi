ENV_DIR  := envs
ENV_LINK := include.mk

include $(ENV_LINK)

# GNU make remakes any included file, then re-execs itself -- so a missing
# include.mk self-heals to the dev instead of erroring on a fresh clone.
$(ENV_LINK):
	@ln -sf $(ENV_DIR)/dev.mk $@

env-%: $(ENV_DIR)/%.mk
	@ln -sf "$<" "$(ENV_LINK)"
	@echo "env -> $*"

# Name of the selected env, available to other recipes.
ENV_NAME := $(basename $(notdir $(realpath $(ENV_LINK))))

.PHONY: env envs
env:
	@echo "$(ENV_NAME)"

envs:
	@ls $(ENV_DIR)/*.mk | xargs -n1 basename | sed 's/\.mk$$//'
