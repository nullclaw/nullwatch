#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
HOME_DIR="${TMP_DIR}/home"
PORT=17710
TOKEN="nullwatch-e2e-token"
SERVER_PID=""

cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP_DIR}"
}

trap cleanup EXIT

mkdir -p "${HOME_DIR}"

FROM_JSON_PAYLOAD="$(cat <<JSON
{"home":"${HOME_DIR}","host":"127.0.0.1","port":${PORT},"data_dir":"data","api_token":"${TOKEN}"}
JSON
)"

FROM_JSON_OUT="$(cd "${ROOT_DIR}" && zig build run -- --from-json "${FROM_JSON_PAYLOAD}")"
echo "${FROM_JSON_OUT}" | grep -q '"status":"ok"'
grep -q "\"port\": ${PORT}" "${HOME_DIR}/config.json"
grep -q '"data_dir": "data"' "${HOME_DIR}/config.json"

MANIFEST_OUT="$(cd "${ROOT_DIR}" && zig build run -- --export-manifest)"
echo "${MANIFEST_OUT}" | grep -q '"name": "nullwatch"'
echo "${MANIFEST_OUT}" | grep -q '"display_name": "NullWatch"'

NULLWATCH_HOME="${HOME_DIR}" \
  zig build run -- serve >"${TMP_DIR}/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

curl -fsS "http://127.0.0.1:${PORT}/health" | grep -q '"status":"ok"'

HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/v1/summary")"
[[ "${HTTP_CODE}" == "401" ]]

AUTH_HEADER="Authorization: Bearer ${TOKEN}"

curl -fsS \
  -H "${AUTH_HEADER}" \
  -H 'content-type: application/json' \
  -d '{"run_id":"run-123","trace_id":"trace-123","span_id":"span-1","source":"nullclaw","operation":"model.call","status":"ok","started_at_ms":1710000000000,"ended_at_ms":1710000000100,"model":"gpt-5","input_tokens":100,"output_tokens":40,"cost_usd":0.02}' \
  "http://127.0.0.1:${PORT}/v1/spans" | grep -q '"id":"spn-1"'

curl -fsS \
  -H "${AUTH_HEADER}" \
  -H 'content-type: application/json' \
  -d '{"run_id":"run-123","eval_key":"helpfulness","scorer":"judge","score":0.93,"verdict":"pass","dataset":"shadow"}' \
  "http://127.0.0.1:${PORT}/v1/evals" | grep -q '"id":"eval-1"'

curl -fsS \
  -H "${AUTH_HEADER}" \
  -H 'content-type: application/json' \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"nullclaw"}}]},"scopeSpans":[{"scope":{"name":"nullclaw-observer"},"spans":[{"traceId":"trace-otlp","spanId":"span-otlp","name":"tool.call","startTimeUnixNano":"1710000000200000000","endTimeUnixNano":"1710000000250000000","attributes":[{"key":"nullwatch.run_id","value":{"stringValue":"run-otlp"}},{"key":"tool","value":{"stringValue":"shell"}},{"key":"success","value":{"boolValue":true}},{"key":"model","value":{"stringValue":"gpt-5-mini"}}],"status":{"code":1}}]}]}]}' \
  "http://127.0.0.1:${PORT}/v1/traces" | grep -q '"accepted_spans":1'

curl -fsS -H "${AUTH_HEADER}" "http://127.0.0.1:${PORT}/v1/spans?source=nullclaw&limit=2" | grep -q '"operation":"tool.call"'
curl -fsS -H "${AUTH_HEADER}" "http://127.0.0.1:${PORT}/v1/evals?verdict=pass" | grep -q '"eval_key":"helpfulness"'
curl -fsS -H "${AUTH_HEADER}" "http://127.0.0.1:${PORT}/v1/runs?verdict=pass" | grep -q '"run_id":"run-123"'
curl -fsS -H "${AUTH_HEADER}" "http://127.0.0.1:${PORT}/v1/runs/run-otlp" | grep -q '"tool_name":"shell"'
curl -fsS -H "${AUTH_HEADER}" "http://127.0.0.1:${PORT}/v1/summary" | grep -q '"run_count":2'

NULLWATCH_HOME="${HOME_DIR}" zig build run -- summary | grep -q '"span_count": 2'
NULLWATCH_HOME="${HOME_DIR}" zig build run -- runs --verdict pass | grep -q '"run_id": "run-123"'
NULLWATCH_HOME="${HOME_DIR}" zig build run -- spans --tool-name shell | grep -q '"run_id": "run-otlp"'

DEMO_DATA_DIR="${TMP_DIR}/demo-data"
DEMO_FIRST="$(cd "${ROOT_DIR}" && zig build run -- demo-seed --data-dir "${DEMO_DATA_DIR}")"
echo "${DEMO_FIRST}" | grep -q '"runs_created": 3'
echo "${DEMO_FIRST}" | grep -q '"runs_skipped": 0'
echo "${DEMO_FIRST}" | grep -q '"spans_created": 11'
echo "${DEMO_FIRST}" | grep -q '"evals_created": 3'

DEMO_SECOND="$(cd "${ROOT_DIR}" && zig build run -- demo-seed --data-dir "${DEMO_DATA_DIR}")"
echo "${DEMO_SECOND}" | grep -q '"runs_created": 0'
echo "${DEMO_SECOND}" | grep -q '"runs_skipped": 3'

zig build run -- summary --data-dir "${DEMO_DATA_DIR}" | grep -q '"run_count": 3'
zig build run -- run demo-tool-failure --data-dir "${DEMO_DATA_DIR}" | grep -q '"overall_verdict": "fail"'

echo "nullwatch e2e: ok"
