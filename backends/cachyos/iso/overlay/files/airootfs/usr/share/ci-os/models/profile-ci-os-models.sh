# shellcheck shell=sh
# Companion OS: tell Hugging Face tools and llama.cpp where the stick's models are (HF_HUB_CACHE, LLAMA_CACHE,
# CI_STICK_CACHE, and HF_HUB_OFFLINE=1 when there is no route out). Prints nothing and exports nothing when no
# model cache is in use. The command is a root-owned script that shell-quotes every value.
if [ -x /usr/bin/ci-os-models ] && [ -z "${CI_OS_MODELS_NO_PROFILE:-}" ]; then
    eval "$(/usr/bin/ci-os-models env --user --format sh 2>/dev/null)" || true
fi
