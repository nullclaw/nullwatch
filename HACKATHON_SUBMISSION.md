# NullWatch Demo Seed For Agent Flight Recorder

## Problem Discovered

NullWatch has useful local observability APIs for spans, evals, run summaries,
OTLP ingest, token usage, cost, and errors. The repository had CLI ingest
examples and an E2E test, but no one-command way to create realistic local demo
data for NullHub or for a new contributor exploring the service.

## Chosen Solution

Add `nullwatch demo-seed`, an idempotent local CLI command that creates a small
set of realistic agent observability runs:

- a passing code-review run
- a failed tool-call run
- a handoff/retry run with checkpoint context

## Why This Idea Was Chosen

The command makes NullWatch demoable without API keys, hosted services, or an
external agent runtime. It supports the broader Agent Flight Recorder work in
NullHub while remaining useful by itself for local development and tests.

## What Was Implemented

- `demo-seed` CLI routing
- deterministic seed data for spans and evals
- idempotency by skipping existing demo run ids
- a unit test covering seed creation and repeat execution
- README usage and NullHub demo notes

## Files Changed

- `src/main.zig`
- `src/demo_seed.zig`
- `README.md`
- `HACKATHON_SUBMISSION.md`

## How To Test Or Demo

```bash
zig build test --summary all
zig build run -- demo-seed
zig build run -- summary
zig build run -- run demo-tool-failure
zig build run -- serve --port 7710
```

Then start NullHub with:

```bash
NULLWATCH_URL=http://127.0.0.1:7710 zig build run -- serve
```

## Limitations And Future Improvements

- The seed data is deterministic and intentionally small.
- Future fixtures could include OpenTelemetry GenAI/OpenInference attributes.
- A later version could support scenario selection, for example
  `demo-seed --scenario failures`.
