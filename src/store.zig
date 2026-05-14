const std = @import("std");
const std_compat = @import("compat.zig");
const domain = @import("domain.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    spans: std.ArrayList(domain.SpanRecord),
    evals: std.ArrayList(domain.EvalRecord),

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !Store {
        var self = Store{
            .allocator = allocator,
            .data_dir = try allocator.dupe(u8, data_dir),
            .spans = .empty,
            .evals = .empty,
        };
        errdefer self.deinit();

        try ensureDirExists(self.data_dir);
        try self.loadSpanLines();
        try self.loadEvalLines();
        return self;
    }

    pub fn deinit(self: *Store) void {
        for (self.spans.items) |item| {
            domain.freeSpanRecord(self.allocator, &item);
        }
        self.spans.deinit(self.allocator);

        for (self.evals.items) |item| {
            domain.freeEvalRecord(self.allocator, &item);
        }
        self.evals.deinit(self.allocator);

        self.allocator.free(self.data_dir);
    }

    pub fn ingestSpan(self: *Store, payload: domain.SpanIngest) !domain.SpanRecord {
        const id = try std.fmt.allocPrint(self.allocator, "spn-{d}", .{self.spans.items.len + 1});
        errdefer self.allocator.free(id);

        const stored_at_ms = std_compat.time.milliTimestamp();
        var record = try domain.materializeSpanRecord(self.allocator, payload, id, stored_at_ms);
        errdefer domain.freeSpanRecord(self.allocator, &record);

        try self.appendJsonLine("spans.jsonl", record);
        try self.spans.append(self.allocator, record);
        return record;
    }

    pub fn ingestEval(self: *Store, payload: domain.EvalIngest) !domain.EvalRecord {
        const id = try std.fmt.allocPrint(self.allocator, "eval-{d}", .{self.evals.items.len + 1});
        errdefer self.allocator.free(id);

        const stored_at_ms = std_compat.time.milliTimestamp();
        var record = try domain.materializeEvalRecord(self.allocator, payload, id, stored_at_ms);
        errdefer domain.freeEvalRecord(self.allocator, &record);

        try self.appendJsonLine("evals.jsonl", record);
        try self.evals.append(self.allocator, record);
        return record;
    }

    pub fn listSpans(self: *const Store, allocator: std.mem.Allocator, filter: domain.SpanFilter) ![]domain.SpanRecord {
        var results: std.ArrayListUnmanaged(domain.SpanRecord) = .empty;
        errdefer results.deinit(allocator);

        var index = self.spans.items.len;
        while (index > 0) {
            index -= 1;
            const span = self.spans.items[index];
            if (!spanMatchesFilter(span, filter)) continue;
            try results.append(allocator, span);
            if (filter.limit) |limit| {
                if (results.items.len >= limit) break;
            }
        }
        return results.toOwnedSlice(allocator);
    }

    pub fn listEvals(self: *const Store, allocator: std.mem.Allocator, filter: domain.EvalFilter) ![]domain.EvalRecord {
        var results: std.ArrayListUnmanaged(domain.EvalRecord) = .empty;
        errdefer results.deinit(allocator);

        var index = self.evals.items.len;
        while (index > 0) {
            index -= 1;
            const eval = self.evals.items[index];
            if (!evalMatchesFilter(eval, filter)) continue;
            try results.append(allocator, eval);
            if (filter.limit) |limit| {
                if (results.items.len >= limit) break;
            }
        }
        return results.toOwnedSlice(allocator);
    }

    pub fn listRuns(self: *const Store, allocator: std.mem.Allocator, filter: domain.RunFilter) ![]domain.RunSummary {
        var items: std.ArrayListUnmanaged(domain.RunSummary) = .empty;
        errdefer {
            for (items.items) |item| {
                allocator.free(item.run_id);
            }
            items.deinit(allocator);
        }

        for (self.spans.items) |span| {
            const idx = try ensureRunSummaryIndex(allocator, &items, span.run_id);
            updateSummaryWithSpan(&items.items[idx], span);
        }
        for (self.evals.items) |eval| {
            const idx = try ensureRunSummaryIndex(allocator, &items, eval.run_id);
            updateSummaryWithEval(&items.items[idx], eval);
        }
        finalizeVerdicts(items.items);

        var write_index: usize = 0;
        for (items.items) |item| {
            if (runMatchesFilter(self, item, filter)) {
                items.items[write_index] = item;
                write_index += 1;
            } else {
                allocator.free(item.run_id);
            }
        }
        items.items.len = write_index;

        sortRunSummaries(items.items);

        if (filter.limit) |limit| {
            if (items.items.len > limit) {
                for (items.items[limit..]) |item| {
                    allocator.free(item.run_id);
                }
                items.items.len = limit;
            }
        }
        return items.toOwnedSlice(allocator);
    }

    pub fn getRunDetail(self: *const Store, allocator: std.mem.Allocator, run_id: []const u8) !?domain.RunDetail {
        var spans: std.ArrayListUnmanaged(domain.SpanRecord) = .empty;
        var evals: std.ArrayListUnmanaged(domain.EvalRecord) = .empty;
        errdefer spans.deinit(allocator);
        errdefer evals.deinit(allocator);

        var summary = domain.RunSummary{
            .run_id = try allocator.dupe(u8, run_id),
        };
        var found = false;

        for (self.spans.items) |span| {
            if (!std.mem.eql(u8, span.run_id, run_id)) continue;
            found = true;
            try spans.append(allocator, span);
            updateSummaryWithSpan(&summary, span);
        }
        for (self.evals.items) |eval| {
            if (!std.mem.eql(u8, eval.run_id, run_id)) continue;
            found = true;
            try evals.append(allocator, eval);
            updateSummaryWithEval(&summary, eval);
        }

        if (!found) {
            allocator.free(summary.run_id);
            spans.deinit(allocator);
            evals.deinit(allocator);
            return null;
        }

        finalizeVerdict(&summary);
        return .{
            .summary = summary,
            .spans = try spans.toOwnedSlice(allocator),
            .evals = try evals.toOwnedSlice(allocator),
        };
    }

    pub fn getSystemSummary(self: *const Store, allocator: std.mem.Allocator) !domain.SystemSummary {
        const runs = try self.listRuns(allocator, .{});
        var summary = domain.SystemSummary{
            .span_count = self.spans.items.len,
            .eval_count = self.evals.items.len,
            .run_count = runs.len,
        };

        for (self.spans.items) |span| {
            if (std.ascii.eqlIgnoreCase(span.status, "error")) summary.error_count += 1;
            summary.total_duration_ms += span.duration_ms;
            summary.total_cost_usd += span.cost_usd orelse 0;
            summary.total_input_tokens += span.input_tokens orelse 0;
            summary.total_output_tokens += span.output_tokens orelse 0;
        }

        for (self.evals.items) |eval| {
            if (std.ascii.eqlIgnoreCase(eval.verdict, "pass")) summary.pass_count += 1;
            if (std.ascii.eqlIgnoreCase(eval.verdict, "fail")) summary.fail_count += 1;
        }

        for (runs) |run| {
            allocator.free(run.run_id);
        }
        allocator.free(runs);
        return summary;
    }

    fn loadSpanLines(self: *Store) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.data_dir, "spans.jsonl" });
        defer self.allocator.free(path);

        const contents = readFileIfExists(self.allocator, path, 8 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer if (contents.len > 0) self.allocator.free(contents);
        if (contents.len == 0) return;

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \r\t");
            if (line.len == 0) continue;

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const parsed = try std.json.parseFromSlice(domain.SpanRecord, arena.allocator(), line, .{ .ignore_unknown_fields = true });
            const owned = try domain.cloneSpanRecord(self.allocator, parsed.value);
            try self.spans.append(self.allocator, owned);
        }
    }

    fn loadEvalLines(self: *Store) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.data_dir, "evals.jsonl" });
        defer self.allocator.free(path);

        const contents = readFileIfExists(self.allocator, path, 8 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer if (contents.len > 0) self.allocator.free(contents);
        if (contents.len == 0) return;

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \r\t");
            if (line.len == 0) continue;

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const parsed = try std.json.parseFromSlice(domain.EvalRecord, arena.allocator(), line, .{ .ignore_unknown_fields = true });
            const owned = try domain.cloneEvalRecord(self.allocator, parsed.value);
            try self.evals.append(self.allocator, owned);
        }
    }

    fn appendJsonLine(self: *Store, file_name: []const u8, value: anytype) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.data_dir, file_name });
        defer self.allocator.free(path);

        const line = try encodeJson(self.allocator, value);
        defer self.allocator.free(line);

        var file = try createFileForAppend(path);
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(line);
        try file.writeAll("\n");
    }
};

fn ensureRunSummaryIndex(
    allocator: std.mem.Allocator,
    items: *std.ArrayListUnmanaged(domain.RunSummary),
    run_id: []const u8,
) !usize {
    for (items.items, 0..) |item, idx| {
        if (std.mem.eql(u8, item.run_id, run_id)) return idx;
    }

    try items.append(allocator, .{
        .run_id = try allocator.dupe(u8, run_id),
    });
    return items.items.len - 1;
}

fn spanMatchesFilter(span: domain.SpanRecord, filter: domain.SpanFilter) bool {
    if (filter.run_id) |run_id| if (!std.mem.eql(u8, span.run_id, run_id)) return false;
    if (filter.trace_id) |trace_id| if (!std.mem.eql(u8, span.trace_id, trace_id)) return false;
    if (filter.source) |source| if (!std.mem.eql(u8, span.source, source)) return false;
    if (filter.operation) |operation| if (!std.mem.eql(u8, span.operation, operation)) return false;
    if (filter.status) |status| if (!std.mem.eql(u8, span.status, status)) return false;
    if (filter.model) |model| {
        if (span.model == null or !std.mem.eql(u8, span.model.?, model)) return false;
    }
    if (filter.tool_name) |tool_name| {
        if (span.tool_name == null or !std.mem.eql(u8, span.tool_name.?, tool_name)) return false;
    }
    if (filter.task_id) |task_id| {
        if (span.task_id == null or !std.mem.eql(u8, span.task_id.?, task_id)) return false;
    }
    if (filter.session_id) |session_id| {
        if (span.session_id == null or !std.mem.eql(u8, span.session_id.?, session_id)) return false;
    }
    if (filter.agent_id) |agent_id| {
        if (span.agent_id == null or !std.mem.eql(u8, span.agent_id.?, agent_id)) return false;
    }
    return true;
}

fn evalMatchesFilter(eval: domain.EvalRecord, filter: domain.EvalFilter) bool {
    if (filter.run_id) |run_id| if (!std.mem.eql(u8, eval.run_id, run_id)) return false;
    if (filter.verdict) |verdict| if (!std.mem.eql(u8, eval.verdict, verdict)) return false;
    if (filter.eval_key) |eval_key| if (!std.mem.eql(u8, eval.eval_key, eval_key)) return false;
    if (filter.scorer) |scorer| if (!std.mem.eql(u8, eval.scorer, scorer)) return false;
    if (filter.dataset) |dataset| {
        if (eval.dataset == null or !std.mem.eql(u8, eval.dataset.?, dataset)) return false;
    }
    return true;
}

fn runMatchesFilter(self: *const Store, run: domain.RunSummary, filter: domain.RunFilter) bool {
    if (filter.run_id) |run_id| if (!std.mem.eql(u8, run.run_id, run_id)) return false;
    if (filter.verdict) |verdict| if (!std.mem.eql(u8, run.overall_verdict, verdict)) return false;

    if (hasRunSpanCriteria(filter)) {
        var span_match = false;
        for (self.spans.items) |span| {
            if (!std.mem.eql(u8, span.run_id, run.run_id)) continue;
            if (filter.source) |source| if (!std.mem.eql(u8, span.source, source)) continue;
            if (filter.operation) |operation| if (!std.mem.eql(u8, span.operation, operation)) continue;
            if (filter.status) |status| if (!std.mem.eql(u8, span.status, status)) continue;
            if (filter.model) |model| {
                if (span.model == null or !std.mem.eql(u8, span.model.?, model)) continue;
            }
            if (filter.tool_name) |tool_name| {
                if (span.tool_name == null or !std.mem.eql(u8, span.tool_name.?, tool_name)) continue;
            }
            span_match = true;
            break;
        }
        if (!span_match) return false;
    }

    if (hasRunEvalCriteria(filter)) {
        var eval_match = false;
        for (self.evals.items) |eval| {
            if (!std.mem.eql(u8, eval.run_id, run.run_id)) continue;
            if (filter.dataset) |dataset| {
                if (eval.dataset == null or !std.mem.eql(u8, eval.dataset.?, dataset)) continue;
            }
            eval_match = true;
            break;
        }
        if (!eval_match) return false;
    }

    return true;
}

fn hasRunSpanCriteria(filter: domain.RunFilter) bool {
    return filter.source != null or
        filter.operation != null or
        filter.status != null or
        filter.model != null or
        filter.tool_name != null;
}

fn hasRunEvalCriteria(filter: domain.RunFilter) bool {
    return filter.dataset != null;
}

fn sortRunSummaries(items: []domain.RunSummary) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and items[j - 1].last_seen_ms < items[j].last_seen_ms) : (j -= 1) {
            std.mem.swap(domain.RunSummary, &items[j - 1], &items[j]);
        }
    }
}

fn updateSummaryWithSpan(summary: *domain.RunSummary, span: domain.SpanRecord) void {
    summary.span_count += 1;
    if (std.ascii.eqlIgnoreCase(span.status, "error")) summary.error_count += 1;
    summary.total_duration_ms += span.duration_ms;
    summary.total_cost_usd += span.cost_usd orelse 0;
    summary.total_input_tokens += span.input_tokens orelse 0;
    summary.total_output_tokens += span.output_tokens orelse 0;

    const ts_start = span.started_at_ms;
    const ts_end = span.ended_at_ms orelse span.stored_at_ms;
    if (summary.first_seen_ms == 0 or ts_start < summary.first_seen_ms) summary.first_seen_ms = ts_start;
    if (summary.last_seen_ms == 0 or ts_end > summary.last_seen_ms) summary.last_seen_ms = ts_end;
}

fn updateSummaryWithEval(summary: *domain.RunSummary, eval: domain.EvalRecord) void {
    summary.eval_count += 1;
    if (std.ascii.eqlIgnoreCase(eval.verdict, "pass")) summary.pass_count += 1;
    if (std.ascii.eqlIgnoreCase(eval.verdict, "fail")) summary.fail_count += 1;
    if (summary.first_seen_ms == 0 or eval.recorded_at_ms < summary.first_seen_ms) summary.first_seen_ms = eval.recorded_at_ms;
    if (summary.last_seen_ms == 0 or eval.recorded_at_ms > summary.last_seen_ms) summary.last_seen_ms = eval.recorded_at_ms;
}

fn finalizeVerdicts(items: []domain.RunSummary) void {
    for (items) |*item| finalizeVerdict(item);
}

fn finalizeVerdict(summary: *domain.RunSummary) void {
    summary.overall_verdict = if (summary.eval_count == 0)
        "no_evals"
    else if (summary.fail_count > 0)
        "fail"
    else if (summary.pass_count > 0)
        "pass"
    else
        "mixed";
}

fn ensureDirExists(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        try std_compat.fs.makePathAbsolute(path);
        return;
    }

    try std_compat.fs.cwd().makePath(path);
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        std_compat.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) return error.FileNotFound;
            return err;
        }
    else
        std_compat.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return error.FileNotFound;
            return err;
        };
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn createFileForAppend(path: []const u8) !std_compat.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std_compat.fs.createFileAbsolute(path, .{ .truncate = false, .read = true });
    }
    return std_compat.fs.cwd().createFile(path, .{ .truncate = false, .read = true });
}

fn encodeJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

test "store ingests and reloads jsonl data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir = std_compat.fs.Dir.wrap(tmp.dir);
    const data_dir = try tmp_dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(data_dir);

    var store = try Store.init(std.testing.allocator, data_dir);
    defer store.deinit();

    _ = try store.ingestSpan(.{
        .run_id = "run-1",
        .trace_id = "trace-1",
        .span_id = "span-1",
        .source = "nullclaw",
        .operation = "model.call",
        .started_at_ms = 100,
        .ended_at_ms = 250,
        .cost_usd = 0.12,
    });
    _ = try store.ingestEval(.{
        .run_id = "run-1",
        .eval_key = "helpfulness",
        .scorer = "heuristic",
        .score = 0.98,
    });

    var store_reload = try Store.init(std.testing.allocator, data_dir);
    defer store_reload.deinit();

    try std.testing.expectEqual(@as(usize, 1), store_reload.spans.items.len);
    try std.testing.expectEqual(@as(usize, 1), store_reload.evals.items.len);
}

test "list APIs filter by run and verdict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir = std_compat.fs.Dir.wrap(tmp.dir);
    const data_dir = try tmp_dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(data_dir);

    var store = try Store.init(std.testing.allocator, data_dir);
    defer store.deinit();

    _ = try store.ingestSpan(.{
        .run_id = "run-a",
        .trace_id = "trace-a",
        .span_id = "span-a",
        .source = "nullclaw",
        .operation = "tool.call",
        .status = "error",
        .started_at_ms = 100,
        .ended_at_ms = 200,
        .tool_name = "shell",
    });
    _ = try store.ingestSpan(.{
        .run_id = "run-b",
        .trace_id = "trace-b",
        .span_id = "span-b",
        .source = "nullclaw",
        .operation = "model.call",
        .started_at_ms = 200,
        .ended_at_ms = 260,
        .model = "gpt-5",
    });
    _ = try store.ingestEval(.{
        .run_id = "run-a",
        .eval_key = "safety",
        .scorer = "judge",
        .score = 0.1,
        .verdict = "fail",
    });

    const spans = try store.listSpans(std.testing.allocator, .{ .tool_name = "shell" });
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 1), spans.len);

    const evals = try store.listEvals(std.testing.allocator, .{ .verdict = "fail" });
    defer std.testing.allocator.free(evals);
    try std.testing.expectEqual(@as(usize, 1), evals.len);

    const runs = try store.listRuns(std.testing.allocator, .{ .verdict = "fail" });
    defer {
        for (runs) |run| std.testing.allocator.free(run.run_id);
        std.testing.allocator.free(runs);
    }
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try std.testing.expectEqualStrings("run-a", runs[0].run_id);
}
