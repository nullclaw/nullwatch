# AGENTS.md — NullWatch Engineering Protocol

Default working protocol for coding agents in this repository. Scope: entire repository.

## 1) Project Snapshot

NullWatch is the execution-intelligence layer of the null stack: traces, evals,
run summaries, costs, latency, and regression signals. Zig 0.16.0, single binary,
headless by design — the product surface is a JSON HTTP API plus a CLI for
ingestion and querying; UI belongs to NullHub, which consumes these endpoints.

Division of labor (do not blur these boundaries):

- `nullclaw` executes work — NullWatch never runs agents
- `nulltickets` owns durable task state — NullWatch owns no queues
- `nullboiler` owns orchestration policy — no scheduling logic here
- `nullhub` owns install/config/UI — no installer or dashboards in this repo
- NullWatch owns traces, evals, run summaries, token/cost accounting

## 2) Architecture Facts

- The implementation is intentionally small (MVP-shaped): file-backed storage,
  JSON HTTP API, CLI. Do not add persistence engines or UI "while here".
- Run and span ingest, eval-result ingest, and run-level summaries are the core
  surface — changes must keep the JSON contracts stable for NullHub consumers.
- Headless workflows only: anything that needs a human viewport belongs in NullHub.

## 3) Engineering Principles

- KISS / YAGNI / DRY, fail fast with explicit errors.
- Determinism: tests must not hit the network or depend on wall-clock ordering.
- Every code change ships with tests; `zig build test --summary all` must show
  0 failures and 0 leaks. Regression tests cite the issue they guard.

## 4) Validation

```bash
zig build test --summary all   # required before every commit
zig fmt --check src/           # required before every commit
zig build                      # dev build
```

## 5) Contribution flow

See [CONTRIBUTING.md](CONTRIBUTING.md).
