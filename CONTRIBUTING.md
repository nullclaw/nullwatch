# Contributing to NullWatch

1. **Read [AGENTS.md](AGENTS.md)** first — headless-by-design constraints and
   the JSON contract stability rules live there.
2. One concern per PR. No drive-by refactors.
3. Before every commit:
   - `zig build test --summary all` — 0 failures, 0 leaks
   - `zig fmt --check src/`
   - API/CLI changes: `bash tests/test_e2e.sh` — CI runs this too, and it
     verifies real ingest/query behavior
4. Every PR runs the shared CI matrix. Keep it green.
5. Bug fixes must include a regression test citing the issue number.
6. Ingest/query API changes must stay backward-compatible for NullHub consumers,
   or be versioned explicitly.