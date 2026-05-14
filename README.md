# nullwatch

Observability, tracing, evals, and optimization signals for `nullclaw`.

`nullwatch` is the execution-intelligence layer in the `null*` stack. It does not run agents, it does not schedule work, and it does not manage UI. It ingests execution traces and eval results, stores them durably, and exposes them through a JSON HTTP API and CLI so `nullhub` or any other client can consume them.

## Role in the stack

- `nullclaw` executes work.
- `nulltickets` owns durable task state.
- `nullboiler` owns orchestration policy.
- `nullhub` owns install, config, and UI.
- `nullwatch` owns traces, evals, run summaries, costs, latency, and regression signals.

This repository intentionally stays headless. The product surface is:

- JSON HTTP API for ingestion and querying.
- CLI commands for local automation and scripts.
- File-backed storage for the bootstrap implementation.

UI belongs elsewhere, primarily in `nullhub`.

## What lives here

- Run and span ingest for `nullclaw` execution telemetry.
- Eval result ingest for scorers, rubrics, regression checks, and datasets.
- Run-level summaries for latency, errors, token usage, and cost.
- Machine-readable capabilities and summary endpoints.
- Headless workflows that a separate UI can compose.

## What does not live here

- Agent runtime logic.
- Queue ownership or task lifecycle source of truth.
- Scheduling, balancing, routing, retries, or orchestration policy.
- Web UI, dashboards, or installer flows.

## Current MVP shape

The implementation is intentionally small but already usable:

- Single Zig binary.
- Local JSONL persistence under `~/.nullwatch/data` by default.
- HTTP API on `127.0.0.1:7710` by default.
- CLI commands for ingesting spans/evals and querying runs, spans, evals, and summaries.
- OTLP/HTTP JSON ingest on `/v1/traces` and `/otlp/v1/traces`.
- `nullhub` integration via `--export-manifest` and `--from-json`.

This gives you a real executable contract now, while keeping room to swap storage later for SQLite or another embedded engine without changing the product boundary.

## Data model

### Span

A span represents one timed execution unit inside a run, for example:

- model call
- tool invocation
- memory lookup
- task transition bridge
- retry or fallback branch

Core fields:

- `run_id`
- `trace_id`
- `span_id`
- `parent_span_id`
- `source`
- `operation`
- `status`
- `started_at_ms`
- `ended_at_ms` or `duration_ms`
- `model`, `tool_name`, `prompt_version`
- `input_tokens`, `output_tokens`, `cost_usd`

### Eval

An eval is a scored assertion attached to a run, for example:

- helpfulness
- policy compliance
- routing correctness
- tool success rate
- regression gate

Core fields:

- `run_id`
- `eval_key`
- `scorer`
- `score`
- `verdict`
- `dataset`
- `notes`

### Run summary

Run summaries are computed views over spans and evals:

- span count
- eval count
- error count
- total duration
- total cost
- total input/output tokens
- pass/fail counts
- overall verdict

## CLI

Build:

```bash
zig build
```

Run the API server:

```bash
zig build run -- serve
```

Run the API server on all interfaces:

```bash
zig build run -- serve --host 0.0.0.0 --port 7710
```

Query summary:

```bash
zig build run -- summary
```

List runs:

```bash
zig build run -- runs --verdict pass --limit 20
```

List spans:

```bash
zig build run -- spans --source nullclaw --tool-name shell --limit 50
```

List evals:

```bash
zig build run -- evals --dataset prod-shadow --verdict fail
```

Ingest a span from the CLI:

```bash
zig build run -- ingest-span --json '{
  "run_id": "run-123",
  "trace_id": "trace-123",
  "span_id": "span-1",
  "source": "nullclaw",
  "operation": "model.call",
  "status": "ok",
  "started_at_ms": 1710000000000,
  "ended_at_ms": 1710000000320,
  "model": "gpt-5",
  "prompt_version": "reply-v3",
  "input_tokens": 420,
  "output_tokens": 96,
  "cost_usd": 0.018
}'
```

Ingest an eval:

```bash
zig build run -- ingest-eval --json '{
  "run_id": "run-123",
  "eval_key": "helpfulness",
  "scorer": "llm-judge",
  "score": 0.94,
  "verdict": "pass",
  "dataset": "prod-shadow"
}'
```

Inspect a run:

```bash
zig build run -- run run-123
```

## HTTP API

### Health

```bash
curl http://127.0.0.1:7710/health
```

### Capabilities

```bash
curl http://127.0.0.1:7710/v1/capabilities
```

### Ingest span

```bash
curl -X POST http://127.0.0.1:7710/v1/spans \
  -H 'content-type: application/json' \
  -d '{
    "run_id": "run-123",
    "trace_id": "trace-123",
    "span_id": "span-1",
    "source": "nullclaw",
    "operation": "tool.call",
    "status": "ok",
    "started_at_ms": 1710000000000,
    "ended_at_ms": 1710000000140,
    "tool_name": "bash"
  }'
```

### Ingest spans in bulk

```bash
curl -X POST http://127.0.0.1:7710/v1/spans/bulk \
  -H 'content-type: application/json' \
  -d '{
    "items": [
      {
        "run_id": "run-123",
        "trace_id": "trace-123",
        "span_id": "span-1",
        "source": "nullclaw",
        "operation": "model.call",
        "started_at_ms": 1710000000000,
        "ended_at_ms": 1710000000100
      }
    ]
  }'
```

### Ingest eval

```bash
curl -X POST http://127.0.0.1:7710/v1/evals \
  -H 'content-type: application/json' \
  -d '{
    "run_id": "run-123",
    "eval_key": "tool_success",
    "scorer": "heuristic",
    "score": 1.0,
    "verdict": "pass"
  }'
```

### Ingest OTLP traces from `nullclaw`

Point `nullclaw` diagnostics OTLP endpoint at `http://127.0.0.1:7710`.

```bash
curl -X POST http://127.0.0.1:7710/v1/traces \
  -H 'content-type: application/json' \
  -d '{
    "resourceSpans": [
      {
        "resource": {
          "attributes": [
            { "key": "service.name", "value": { "stringValue": "nullclaw" } }
          ]
        },
        "scopeSpans": [
          {
            "spans": [
              {
                "traceId": "trace-otlp",
                "spanId": "span-otlp",
                "name": "tool.call",
                "startTimeUnixNano": "1710000000200000000",
                "endTimeUnixNano": "1710000000250000000",
                "attributes": [
                  { "key": "nullwatch.run_id", "value": { "stringValue": "run-otlp" } },
                  { "key": "tool", "value": { "stringValue": "shell" } },
                  { "key": "success", "value": { "boolValue": true } }
                ],
                "status": { "code": 1 }
              }
            ]
          }
        ]
      }
    ]
  }'
```

### List spans

```bash
curl 'http://127.0.0.1:7710/v1/spans?source=nullclaw&status=error&limit=50'
```

### List evals

```bash
curl 'http://127.0.0.1:7710/v1/evals?verdict=fail&dataset=shadow&limit=50'
```

### List runs

```bash
curl http://127.0.0.1:7710/v1/runs?limit=20
```

### Get run detail

```bash
curl http://127.0.0.1:7710/v1/runs/run-123
```

## Config

Default config path:

- `~/.nullwatch/config.json`

Default config:

```json
{
  "host": "127.0.0.1",
  "port": 7710,
  "data_dir": "data",
  "api_token": null
}
```

Because `data_dir` is resolved relative to the config file, the default data directory becomes `~/.nullwatch/data`.

## NullHub integration

`nullwatch` exports a `nullhub` manifest directly from the binary:

```bash
zig build run -- --export-manifest
```

And it can bootstrap its own config from wizard answers:

```bash
zig build run -- --from-json '{"home":"~/.nullwatch","port":7710,"data_dir":"data"}'
```

This keeps the service headless while letting `nullhub` own install/setup UI.

## CI and releases

- `tests/test_e2e.sh` boots a real server and validates auth, ingest, OTLP mapping, and CLI queries.
- `.github/workflows/ci.yml` runs unit tests, Linux E2E, and host builds on Linux/macOS/Windows.
- `.github/workflows/release.yml` builds tagged release artifacts for Linux, macOS, and Windows and publishes them to GitHub Releases.
- `scripts/build-release.sh` produces the same release artifact names locally plus `SHA256SUMS`.

## Near-term next steps

- Replace JSONL storage with embedded SQLite while preserving the API contract.
- Add dataset, prompt version, and experiment entities.
- Add regression diff endpoints for comparing prompt/model/strategy versions.
- Add alert rules and anomaly summaries that `nullhub` can render.

## Community SDKs
- **[nullwatch-python-sdk](https://github.com/nullclaw/nullwatch-python-sdk/)** — Python SDK with zero required dependencies. Ships built-in eval scorers for RAG hallucination detection ([LettuceDetect](https://github.com/KRLabsOrg/LettuceDetect)) and tool-call schema validation.
