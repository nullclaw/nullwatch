const std = @import("std");
const domain = @import("domain.zig");
const Store = @import("store.zig").Store;

pub const SeedSummary = struct {
    status: []const u8 = "ok",
    runs_created: usize = 0,
    runs_skipped: usize = 0,
    spans_created: usize = 0,
    evals_created: usize = 0,
};

const base_ms: i64 = 1_710_000_000_000;

pub fn seed(allocator: std.mem.Allocator, store: *Store) !SeedSummary {
    var summary = SeedSummary{};

    try seedReviewPass(allocator, store, &summary);
    try seedToolFailure(allocator, store, &summary);
    try seedHandoffRetry(allocator, store, &summary);

    return summary;
}

fn runExists(allocator: std.mem.Allocator, store: *Store, run_id: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const detail = try store.getRunDetail(arena.allocator(), run_id);
    return detail != null;
}

fn seedReviewPass(allocator: std.mem.Allocator, store: *Store, summary: *SeedSummary) !void {
    const run_id = "demo-code-review-pass";
    if (try runExists(allocator, store, run_id)) {
        summary.runs_skipped += 1;
        return;
    }

    try addSpan(store, summary, .{
        .run_id = run_id,
        .trace_id = "trace-demo-review-pass",
        .span_id = "review-pass-root",
        .source = "nullclaw",
        .operation = "agent.run",
        .status = "ok",
        .started_at_ms = base_ms,
        .ended_at_ms = base_ms + 1420,
        .agent_id = "reviewer-1",
        .task_id = "ticket-demo-101",
        .attributes_json = "{\"pipeline_id\":\"code-review\",\"stage\":\"review\"}",
    });
    try addSpan(store, summary, .{
        .run_id = run_id,
        .trace_id = "trace-demo-review-pass",
        .span_id = "review-pass-model",
        .parent_span_id = "review-pass-root",
        .source = "nullclaw",
        .operation = "model.call",
        .status = "ok",
        .started_at_ms = base_ms + 80,
        .ended_at_ms = base_ms + 940,
        .agent_id = "reviewer-1",
        .model = "gpt-5-mini",
        .input_tokens = 1280,
        .output_tokens = 420,
        .cost_usd = 0.013,
    });
    try addSpan(store, summary, .{
        .run_id = run_id,
        .trace_id = "trace-demo-review-pass",
        .span_id = "review-pass-transition",
        .parent_span_id = "review-pass-root",
        .source = "nulltickets",
        .operation = "tracker.transition",
        .status = "ok",
        .started_at_ms = base_ms + 1020,
        .ended_at_ms = base_ms + 1180,
        .task_id = "ticket-demo-101",
        .attributes_json = "{\"from\":\"review\",\"to\":\"done\",\"trigger\":\"approve\"}",
    });
    try addEval(store, summary, .{
        .run_id = run_id,
        .eval_key = "review_quality",
        .scorer = "demo-rubric",
        .score = 0.94,
        .verdict = "pass",
        .dataset = "flight-recorder-demo",
        .notes = "Review found the intended issue and approved after tests.",
        .recorded_at_ms = base_ms + 1500,
    });

    summary.runs_created += 1;
}

fn seedToolFailure(allocator: std.mem.Allocator, store: *Store, summary: *SeedSummary) !void {
    const run_id = "demo-tool-failure";
    if (try runExists(allocator, store, run_id)) {
        summary.runs_skipped += 1;
        return;
    }

    try addSpan(store, summary, .{
        .run_id = run_id,
        .trace_id = "trace-demo-tool-failure",
        .span_id = "tool-failure-root",
        .source = "nullboiler",
        .operation = "workflow.step",
        .status = "error",
        .started_at_ms = base_ms + 10_000,
        .ended_at_ms = base_ms + 13_840,
        .agent_id = "coder-1",
        .task_id = "ticket-demo-202",
        .error_message = "workflow failed after shell tool error",
        .attributes_json = "{\"workflow_id\":\"bug-fix\",\"node\":\"run-tests\"}",
    });
    try addSpan(store, summary, .{
        .run_id = run_id,
        .trace_id = "trace-demo-tool-failure",
        .span_id = "tool-failure-model",
        .parent_span_id = "tool-failure-root",
        .source = "nullclaw",
        .operation = "model.call",
        .status = "ok",
        .started_at_ms = base_ms + 10_120,
        .ended_at_ms = base_ms + 11_050,
        .agent_id = "coder-1",
        .model = "gpt-5-mini",
        .input_tokens = 2140,
        .output_tokens = 620,
        .cost_usd = 0.022,
    });
    try addSpan(store, summary, .{
        .run_id = run_id,
        .trace_id = "trace-demo-tool-failure",
        .span_id = "tool-failure-shell",
        .parent_span_id = "tool-failure-root",
        .source = "nullclaw",
        .operation = "tool.call",
        .status = "error",
        .started_at_ms = base_ms + 11_100,
        .ended_at_ms = base_ms + 13_600,
        .agent_id = "coder-1",
        .tool_name = "shell",
        .error_message = "zig build test exited with status 1",
        .attributes_json = "{\"command\":\"zig build test --summary all\",\"exit_code\":1}",
    });
    try addSpan(store, summary, .{
        .run_id = run_id,
        .trace_id = "trace-demo-tool-failure",
        .span_id = "tool-failure-event",
        .parent_span_id = "tool-failure-root",
        .source = "nulltickets",
        .operation = "run.event",
        .status = "ok",
        .started_at_ms = base_ms + 13_660,
        .ended_at_ms = base_ms + 13_760,
        .task_id = "ticket-demo-202",
        .attributes_json = "{\"kind\":\"test_failure\",\"artifact\":\"zig-test-output.txt\"}",
    });
    try addEval(store, summary, .{
        .run_id = run_id,
        .eval_key = "tool_success",
        .scorer = "demo-rubric",
        .score = 0.31,
        .verdict = "fail",
        .dataset = "flight-recorder-demo",
        .notes = "The workflow surfaced a failing shell tool call with enough context to debug.",
        .recorded_at_ms = base_ms + 14_000,
    });

    summary.runs_created += 1;
}

fn seedHandoffRetry(allocator: std.mem.Allocator, store: *Store, summary: *SeedSummary) !void {
    const run_id = "demo-handoff-retry";
    if (try runExists(allocator, store, run_id)) {
        summary.runs_skipped += 1;
        return;
    }

    try addSpan(store, summary, .{
        .run_id = run_id,
        .trace_id = "trace-demo-handoff-retry",
        .span_id = "handoff-root",
        .source = "nullboiler",
        .operation = "workflow.run",
        .status = "ok",
        .started_at_ms = base_ms + 20_000,
        .ended_at_ms = base_ms + 24_500,
        .task_id = "ticket-demo-303",
        .attributes_json = "{\"workflow_id\":\"feature-dev\",\"checkpoint_count\":3}",
    });
    try addSpan(store, summary, .{
        .run_id = run_id,
        .trace_id = "trace-demo-handoff-retry",
        .span_id = "handoff-analyst",
        .parent_span_id = "handoff-root",
        .source = "nullclaw",
        .operation = "agent.handoff",
        .status = "ok",
        .started_at_ms = base_ms + 20_100,
        .ended_at_ms = base_ms + 21_150,
        .agent_id = "analyst-1",
        .attributes_json = "{\"to_agent\":\"coder-1\",\"reason\":\"implementation required\"}",
    });
    try addSpan(store, summary, .{
        .run_id = run_id,
        .trace_id = "trace-demo-handoff-retry",
        .span_id = "handoff-coder",
        .parent_span_id = "handoff-root",
        .source = "nullclaw",
        .operation = "agent.handoff",
        .status = "ok",
        .started_at_ms = base_ms + 21_220,
        .ended_at_ms = base_ms + 23_800,
        .agent_id = "coder-1",
        .attributes_json = "{\"to_agent\":\"reviewer-1\",\"reason\":\"ready for review\",\"retry\":1}",
    });
    try addSpan(store, summary, .{
        .run_id = run_id,
        .trace_id = "trace-demo-handoff-retry",
        .span_id = "handoff-checkpoint",
        .parent_span_id = "handoff-root",
        .source = "nullboiler",
        .operation = "checkpoint.created",
        .status = "ok",
        .started_at_ms = base_ms + 23_920,
        .ended_at_ms = base_ms + 24_020,
        .attributes_json = "{\"checkpoint_id\":\"cp-demo-303-3\",\"node\":\"review\"}",
    });
    try addEval(store, summary, .{
        .run_id = run_id,
        .eval_key = "handoff_budget",
        .scorer = "demo-rubric",
        .score = 0.78,
        .verdict = "pass",
        .dataset = "flight-recorder-demo",
        .notes = "The handoff chain stayed within the expected retry budget.",
        .recorded_at_ms = base_ms + 24_800,
    });

    summary.runs_created += 1;
}

fn addSpan(store: *Store, summary: *SeedSummary, payload: domain.SpanIngest) !void {
    _ = try store.ingestSpan(payload);
    summary.spans_created += 1;
}

fn addEval(store: *Store, summary: *SeedSummary, payload: domain.EvalIngest) !void {
    _ = try store.ingestEval(payload);
    summary.evals_created += 1;
}

test "demo seed creates local observability runs and is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir = @import("compat.zig").fs.Dir.wrap(tmp.dir);
    const data_dir = try tmp_dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(data_dir);

    var store = try Store.init(std.testing.allocator, data_dir);
    defer store.deinit();

    const first = try seed(std.testing.allocator, &store);
    try std.testing.expectEqual(@as(usize, 3), first.runs_created);
    try std.testing.expectEqual(@as(usize, 0), first.runs_skipped);
    try std.testing.expectEqual(@as(usize, 11), first.spans_created);
    try std.testing.expectEqual(@as(usize, 3), first.evals_created);

    const second = try seed(std.testing.allocator, &store);
    try std.testing.expectEqual(@as(usize, 0), second.runs_created);
    try std.testing.expectEqual(@as(usize, 3), second.runs_skipped);

    const summary = try store.getSystemSummary(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), summary.run_count);
    try std.testing.expectEqual(@as(usize, 11), summary.span_count);
    try std.testing.expectEqual(@as(usize, 3), summary.eval_count);
    try std.testing.expectEqual(@as(usize, 2), summary.error_count);
    try std.testing.expectEqual(@as(usize, 1), summary.fail_count);
}
