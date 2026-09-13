#!/bin/bash

set -euo pipefail

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
    # "source" field decides which provider the model belongs to. Normalize
    # to a safe {data:[...]} shape (objects only) so a malformed or empty
    # response cannot abort the script under set -e.
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

    # Stamp contextWindow onto each entry where the catalogue exposes a size:
    # llama.cpp reports meta.n_ctx for loaded instances and the --ctx-size
    # launch argument for all of them, vLLM uses max_model_len, Ollama
    # context_window. Entries without a positive size are left untouched so
    # pi falls back to its 128000 default.
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

    # The first model decides whether the server speaks the llama.cpp dialect;
    # if so, export the env vars pi's built-in llama.cpp provider reads.
    PROVIDER_ID="${RAMALAMA_PROVIDER}"
    if [[ "${RAMALAMA_PROVIDER}" == "llama.cpp" ]] && \
       [[ $(printf '%s\n' "${MODELS_DATA}" | jq -r '.data[0].owned_by') == 'llamacpp' ]]; then
        export LLAMA_BASE_URL="${BASE_URL}"
        export LLAMA_API_KEY="${API_KEY}"
    else
        PROVIDER_ID='ramalama'
    fi

    mkdir -p "$(dirname "${MODELS_JSON}")"

    # Emit models.json. In llama.cpp mode the primary model is exposed through
    # pi's built-in llama.cpp provider and the remaining models through the
    # ramalama provider; in ramalama mode every model goes to ramalama.
    jq -n \
        --arg base "${BASE_URL}/v1" \
        --arg key "${API_KEY}" \
        --arg ramalama "${PROVIDER_ID}" \
        --arg primary "${RAMALAMA_PI_MODEL:-}" \
        --argjson data "${MODELS_DATA}" \
        '
          def entry: {id} + (if .contextWindow then {contextWindow} else {} end);
          ($data.data | unique_by(.id)) as $all
          | ($all | map(select(.source != "preset" or .owned_by != "llamacpp"))) as $nonPreset
          | ($all | map(select(.id == $primary)) | first) as $primaryEntry
          | {
              providers: (
                if $ramalama == "llama.cpp"
                then
                  (if ($nonPreset | length) > 0
                   then { ramalama: {
                        baseUrl: $base,
                        api: "openai-completions",
                        apiKey: $key,
                        models: ($nonPreset | map(entry))
                      }}
                   else {}
                   end)
                  + (if $all[0].owned_by == "llamacpp"
                    then { "llama.cpp": {
                        baseUrl: $base,
                        api: "openai-completions",
                        apiKey: $key,
                        models: [if $primaryEntry then ($primaryEntry | entry) else {id: $primary} end]
                      }}
                    else {}
                    end)
                else
                  { ramalama: {
                    baseUrl: $base,
                    api: "openai-completions",
                    apiKey: $key,
                    models: ($all | map(entry))
                  }}
                end
              )
            }
        ' > "${MODELS_JSON}"
fi

exec pi "$@"
