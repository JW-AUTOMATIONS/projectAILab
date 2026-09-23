#!/usr/bin/env bash
# Measure prompt-processing and generation speed of the running llama-servers.
#   scripts/bench.sh                 # main (8081) and aux (8082)
#   scripts/bench.sh 8081 2048 256   # port, prompt tokens (approx), generated tokens
#
# Re-run after changing MAIN_N_CPU_MOE / cpusets to compare configurations.
set -euo pipefail

bench() {
  local port=$1 n_prompt=$2 n_gen=$3 prompt resp
  if ! curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
    echo "port $port: not up"
    return
  fi
  # ~1 token per repetition of "hello " for most tokenizers.
  prompt=$(printf 'hello %.0s' $(seq "$n_prompt"))
  resp=$(jq -n --arg p "$prompt" --argjson n "$n_gen" \
      '{prompt: $p, n_predict: $n, cache_prompt: false, ignore_eos: true, temperature: 0}' |
    curl -fsS "http://127.0.0.1:$port/completion" -H 'Content-Type: application/json' -d @-)
  jq -r --arg port "$port" '.timings |
    "port \($port): prompt \(.prompt_n) tok @ \(.prompt_per_second | floor) t/s | " +
    "gen \(.predicted_n) tok @ \(.predicted_per_second * 10 | floor / 10) t/s"' <<<"$resp"
}

if (($#)); then
  bench "$1" "${2:-1024}" "${3:-128}"
else
  bench 8081 1024 128
  bench 8082 1024 128
fi
