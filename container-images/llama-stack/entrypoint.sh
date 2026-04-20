#! /bin/bash

# shellcheck source=/dev/null
source /.venv/bin/activate

if [ $# -eq 0 ]; then
    exec bash
else
    case "$RAMALAMA_RUNTIME" in
        vllm)
            export VLLM_URL="$RAMALAMA_URL"
            ;;
        llama.cpp)
            export LLAMA_CPP_SERVER_URL="$RAMALAMA_URL"
            ;;
        mlx|*)
            export LLAMA_OPENAI_COMPAT_URL="$RAMALAMA_URL"
            ;;
    esac
    unset RAMALAMA_URL

    exec "$@"
fi
