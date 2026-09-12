#!/bin/bash

set -euo pipefail

PI_MODEL_ARGS=()

if [[ -n "${RAMALAMA_PI_BASE_URL:-}" ]]; then
    MODELS_JSON="/home/node/.pi/agent/models.json"
    # Mirror ramalama's normalize_server_url: accept a trailing /v1 and
    # normalize to the server root so /v1 is appended exactly once below.
    BASE_URL="${RAMALAMA_PI_BASE_URL%/}"
    BASE_URL="${BASE_URL%/v1}"
    API_KEY="${RAMALAMA_PI_API_KEY:-local}"
    RAMALAMA_PROVIDER="${RAMALAMA_PI_PROVIDER:-ramalama}"
    ENDPOINT_URL="${BASE_URL}/v1/models"

    # Best-effort fetch of the server's /v1/models catalogue. Each entry's
    # "source" field marks llama.cpp model presets. Normalize to a safe
    # {data:[...]} shape (objects only) so a malformed or empty response
    # cannot abort the script under set -e.
    if ! MODELS_DATA="$(curl -fsSL --max-time 5 -H "Authorization: Bearer ${API_KEY}" "${ENDPOINT_URL}" 2>/dev/null)" \
        || [[ -z "${MODELS_DATA}" ]]; then
        echo "warning: no model list from ${ENDPOINT_URL}; continuing with an empty catalog" >&2
        MODELS_DATA='{"data":[]}'
    fi
    MODELS_DATA="$(printf '%s\n' "${MODELS_DATA}" | jq -c '
        if type=="object"
        then (.data |= (if type=="array" then map(select(type=="object")) else [] end))
        else {data:[]}
        end' 2>/dev/null || echo '{"data":[]}')"

    # Stamp contextWindow onto each entry where the catalogue exposes a
    # size: llama.cpp reports meta.n_ctx for loaded instances and the
    # --ctx-size launch argument for all of them, vLLM uses max_model_len,
    # Ollama context_window. Entries without a positive size are left
    # untouched so pi falls back to its 128000 default.
    MODELS_DATA="$(printf '%s\n' "${MODELS_DATA}" | jq -c '
        def arg_value($name):
            index($name) as $i
            | (if $i then .[$i + 1] else null end) as $v
            | (if ($v | type) == "number" then $v
               elif ($v | type) == "string" then ($v | tonumber?) // null
               else null end);
        .data |= map(
            (.meta.n_ctx? // .max_model_len? // .context_window?
               // ((.status.args? // []) | arg_value("--ctx-size"))) as $ctx
            | if ($ctx | type) == "number" and $ctx > 0
              then . + {contextWindow: $ctx}
              else .
              end
        )' 2>/dev/null || echo '{"data":[]}')"

    # The first model decides whether the server speaks the llama.cpp
    # dialect; if so, configure pi's built-in llama.cpp provider via the
    # environment variables it reads.
    if [[ "${RAMALAMA_PROVIDER}" == "llama.cpp" ]] && \
       [[ $(printf '%s\n' "${MODELS_DATA}" | jq -r '.data[0].owned_by') == 'llamacpp' ]]; then
        export LLAMA_BASE_URL="${BASE_URL}"
        export LLAMA_API_KEY="${API_KEY}"
        PROVIDER_ID='llama.cpp'
    else
        PROVIDER_ID='ramalama'
    fi

    mkdir -p "$(dirname "${MODELS_JSON}")"

    # Emit models.json: the llama.cpp provider registers only the preset
    # models; every other provider registers all models.
    jq -n \
        --arg base "${BASE_URL}/v1" \
        --arg key "${API_KEY}" \
        --arg provider "${PROVIDER_ID}" \
        --argjson data "${MODELS_DATA}" \
        '
          def entry: {id} + (if .contextWindow then {contextWindow} else {} end);
          ($data.data | unique_by(.id)) as $all
          | ($all | map(select(.source == "preset" and .owned_by == "llamacpp"))) as $presets
          | {
              providers: {
                ($provider): {
                  baseUrl: $base,
                  api: "openai-completions",
                  apiKey: $key,
                  models: ((if $provider == "llama.cpp" then $presets else $all end) | map(entry))
                }
              }
            }
        ' > "${MODELS_JSON}"

    if [[ $(printf '%s\n' "${MODELS_DATA}" | jq '.data | length') -eq 0 ]]; then
        echo "warning: ${MODELS_JSON} has no models; pi will report 'No models available'" >&2
    fi

    # Make the model ramalama serves (RAMALAMA_PI_MODEL) pi's startup model;
    # without it pi starts with the first model in the config. Only point at
    # models the catalogue actually lists so pi does not request unknown ids.
    if [[ -n "${RAMALAMA_PI_MODEL:-}" ]]; then
        COUNT=$(printf '%s\n' "${MODELS_DATA}" | jq --arg id "${RAMALAMA_PI_MODEL}" \
            '[.data[] | select(.id == $id)] | length' 2>/dev/null)
        if [[ "${COUNT}" == 1 ]]; then
            PI_MODEL_ARGS=(--model "${PROVIDER_ID}/${RAMALAMA_PI_MODEL}")
        fi
    fi
fi

exec pi "${PI_MODEL_ARGS[@]}" "$@"
