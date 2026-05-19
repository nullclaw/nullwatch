const std = @import("std");
const std_compat = @import("compat.zig");
const api = @import("api.zig");
const config = @import("config.zig");
const demo_seed = @import("demo_seed.zig");
const domain = @import("domain.zig");
const Store = @import("store.zig").Store;
const version = @import("version.zig");

const max_request_size: usize = 256 * 1024;
const request_read_chunk: usize = 4096;

const RuntimeConfig = struct {
    host: []const u8,
    port: u16,
    data_dir: []const u8,
    api_token: ?[]const u8,

    fn deinit(self: *RuntimeConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.data_dir);
        if (self.api_token) |token| allocator.free(token);
    }
};

const RuntimeOverrides = struct {
    host: ?[]const u8 = null,
    port: ?u16 = null,
    data_dir: ?[]const u8 = null,
    token: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
};

const ArgCursor = struct {
    args: []const [:0]const u8,
    index: usize = 0,

    fn next(self: *ArgCursor) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }
};

pub fn main(init: std.process.Init) !void {
    std_compat.initProcess(init);
    const allocator = std.heap.smp_allocator;

    const args = try std_compat.process.argsAlloc(allocator);
    defer std_compat.process.argsFree(allocator, args);

    if (args.len > 1) {
        const first_arg = args[1];
        if (std.mem.eql(u8, first_arg, "--export-manifest")) {
            try @import("export_manifest.zig").run();
            return;
        }
        if (std.mem.eql(u8, first_arg, "--from-json")) {
            if (args.len > 2) {
                const json_str = args[2];
                try @import("from_json.zig").run(allocator, json_str);
            } else {
                std.debug.print("error: --from-json requires a JSON argument\n", .{});
                std.process.exit(1);
            }
            return;
        }
    }

    var cursor = ArgCursor{
        .args = args,
        .index = 1,
    };
    const command = cursor.next() orelse "serve";

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        std.debug.print("nullwatch v{s}\n", .{version.string});
        return;
    }

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "serve")) {
        var parsed = try parseServeArgs(allocator, &cursor);
        defer parsed.runtime.deinit(allocator);
        try runServer(allocator, parsed.runtime);
        return;
    }

    if (std.mem.eql(u8, command, "summary")) {
        var parsed = try parseCommonArgs(allocator, &cursor);
        defer parsed.deinit(allocator);
        try runSummaryCommand(allocator, parsed.runtime);
        return;
    }

    if (std.mem.eql(u8, command, "runs")) {
        var parsed = try parseRunsArgs(allocator, &cursor);
        defer parsed.common.runtime.deinit(allocator);
        try runRunsCommand(allocator, parsed.common.runtime, parsed.filter);
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        var parsed = try parseRunDetailArgs(allocator, &cursor);
        defer parsed.common.runtime.deinit(allocator);
        try runDetailCommand(allocator, parsed.common.runtime, parsed.run_id);
        return;
    }

    if (std.mem.eql(u8, command, "spans")) {
        var parsed = try parseSpansArgs(allocator, &cursor);
        defer parsed.common.runtime.deinit(allocator);
        try runSpansCommand(allocator, parsed.common.runtime, parsed.filter);
        return;
    }

    if (std.mem.eql(u8, command, "evals")) {
        var parsed = try parseEvalsArgs(allocator, &cursor);
        defer parsed.common.runtime.deinit(allocator);
        try runEvalsCommand(allocator, parsed.common.runtime, parsed.filter);
        return;
    }

    if (std.mem.eql(u8, command, "ingest-span")) {
        var parsed = try parseJsonIngestArgs(allocator, &cursor);
        defer parsed.common.runtime.deinit(allocator);
        try runSpanIngestCommand(allocator, parsed.common.runtime, parsed.json_payload);
        return;
    }

    if (std.mem.eql(u8, command, "ingest-eval")) {
        var parsed = try parseJsonIngestArgs(allocator, &cursor);
        defer parsed.common.runtime.deinit(allocator);
        try runEvalIngestCommand(allocator, parsed.common.runtime, parsed.json_payload);
        return;
    }

    if (std.mem.eql(u8, command, "demo-seed")) {
        var parsed = try parseCommonArgs(allocator, &cursor);
        defer parsed.deinit(allocator);
        try runDemoSeedCommand(allocator, parsed.runtime);
        return;
    }

    std.debug.print("unknown command: {s}\n\n", .{command});
    printUsage();
    std.process.exit(1);
}

fn runServer(allocator: std.mem.Allocator, runtime: RuntimeConfig) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    const addr = try std.Io.net.IpAddress.resolve(std_compat.io(), runtime.host, runtime.port);
    var server = try addr.listen(std_compat.io(), .{ .reuse_address = true });
    defer server.deinit(std_compat.io());

    std.debug.print("nullwatch v{s}\n", .{version.string});
    std.debug.print("data dir: {s}\n", .{runtime.data_dir});
    std.debug.print("listening on http://{s}:{d}\n", .{ runtime.host, runtime.port });

    while (true) {
        var conn = server.accept(std_compat.io()) catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        defer conn.close(std_compat.io());

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const req_alloc = arena.allocator();

        const full_request = readHttpRequest(req_alloc, &conn, max_request_size) catch |err| {
            std.debug.print("read error: {}\n", .{err});
            continue;
        } orelse continue;

        const first_line_end = std.mem.indexOf(u8, full_request, "\r\n") orelse continue;
        const first_line = full_request[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse continue;
        const target = parts.next() orelse continue;

        const body = api.extractBody(full_request);
        var ctx = api.Context{
            .store = &store,
            .allocator = req_alloc,
            .required_api_token = runtime.api_token,
        };
        const response = api.handleRequest(&ctx, method, target, body, full_request);

        var resp_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(
            &resp_buf,
            "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ response.status, response.body.len },
        ) catch continue;
        var resp_write_buffer: [1024]u8 = undefined;
        var writer = conn.writer(std_compat.io(), &resp_write_buffer);
        writer.interface.writeAll(header) catch continue;
        writer.interface.writeAll(response.body) catch continue;
        writer.interface.flush() catch continue;
    }
}

fn readHttpRequest(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, max_bytes: usize) !?[]u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    var read_buffer: [request_read_chunk]u8 = undefined;
    var reader = stream.reader(std_compat.io(), &read_buffer);

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (buffer.items.len == 0) return null;
                return error.UnexpectedEof;
            },
            else => |e| return e,
        };

        try buffer.appendSlice(allocator, line);
        if (buffer.items.len > max_bytes) return error.RequestTooLarge;

        if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
    }

    const header_end = std.mem.indexOf(u8, buffer.items, "\r\n\r\n") orelse return error.InvalidRequest;
    const content_len = if (api.extractHeader(buffer.items[0 .. header_end + 4], "Content-Length")) |cl_str|
        (std.fmt.parseInt(usize, cl_str, 10) catch return error.InvalidContentLength)
    else
        0;

    const required = header_end + 4 + content_len;
    if (required > max_bytes) return error.RequestTooLarge;

    if (content_len > 0) {
        const body = try allocator.alloc(u8, content_len);
        defer allocator.free(body);
        try reader.interface.readSliceAll(body);
        try buffer.appendSlice(allocator, body);
    }

    return try allocator.dupe(u8, buffer.items[0..required]);
}

fn runSummaryCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const summary = try store.getSystemSummary(arena.allocator());
    try writeJsonToStdout(allocator, summary);
}

fn runRunsCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, filter: domain.RunFilter) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const runs = try store.listRuns(arena.allocator(), filter);
    const RunListResponse = struct {
        items: []domain.RunSummary,
    };
    try writeJsonToStdout(allocator, RunListResponse{ .items = runs });
}

fn runDetailCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, run_id: []const u8) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const detail = try store.getRunDetail(arena.allocator(), run_id);
    if (detail == null) {
        std.debug.print("run not found: {s}\n", .{run_id});
        std.process.exit(1);
    }
    try writeJsonToStdout(allocator, detail.?);
}

fn runSpansCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, filter: domain.SpanFilter) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const spans = try store.listSpans(arena.allocator(), filter);
    const SpanListResponse = struct {
        items: []domain.SpanRecord,
    };
    try writeJsonToStdout(allocator, SpanListResponse{ .items = spans });
}

fn runEvalsCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, filter: domain.EvalFilter) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const evals = try store.listEvals(arena.allocator(), filter);
    const EvalListResponse = struct {
        items: []domain.EvalRecord,
    };
    try writeJsonToStdout(allocator, EvalListResponse{ .items = evals });
}

fn runSpanIngestCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, json_payload: []const u8) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    const parsed = try std.json.parseFromSlice(domain.SpanIngest, allocator, json_payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const record = try store.ingestSpan(parsed.value);
    try writeJsonToStdout(allocator, record);
}

fn runEvalIngestCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, json_payload: []const u8) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    const parsed = try std.json.parseFromSlice(domain.EvalIngest, allocator, json_payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const record = try store.ingestEval(parsed.value);
    try writeJsonToStdout(allocator, record);
}

fn runDemoSeedCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    const summary = try demo_seed.seed(allocator, &store);
    try writeJsonToStdout(allocator, summary);
}

fn parseServeArgs(allocator: std.mem.Allocator, args: *ArgCursor) !struct { runtime: RuntimeConfig } {
    var overrides = RuntimeOverrides{};

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, true)) continue;
        return error.InvalidArgument;
    }

    return .{ .runtime = try resolveRuntimeConfig(allocator, overrides) };
}

fn parseCommonArgs(allocator: std.mem.Allocator, args: *ArgCursor) !struct {
    runtime: RuntimeConfig,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.runtime.deinit(alloc);
    }
} {
    var overrides = RuntimeOverrides{};
    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        return error.InvalidArgument;
    }

    return .{ .runtime = try resolveRuntimeConfig(allocator, overrides) };
}

fn parseRunsArgs(allocator: std.mem.Allocator, args: *ArgCursor) !struct {
    common: struct { runtime: RuntimeConfig },
    filter: domain.RunFilter,
} {
    var overrides = RuntimeOverrides{};
    var filter = domain.RunFilter{};

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        if (std.mem.eql(u8, arg, "--run-id")) {
            filter.run_id = try requireNext(args, "--run-id");
        } else if (std.mem.eql(u8, arg, "--source")) {
            filter.source = try requireNext(args, "--source");
        } else if (std.mem.eql(u8, arg, "--operation")) {
            filter.operation = try requireNext(args, "--operation");
        } else if (std.mem.eql(u8, arg, "--status")) {
            filter.status = try requireNext(args, "--status");
        } else if (std.mem.eql(u8, arg, "--model")) {
            filter.model = try requireNext(args, "--model");
        } else if (std.mem.eql(u8, arg, "--tool-name")) {
            filter.tool_name = try requireNext(args, "--tool-name");
        } else if (std.mem.eql(u8, arg, "--verdict")) {
            filter.verdict = try requireNext(args, "--verdict");
        } else if (std.mem.eql(u8, arg, "--dataset")) {
            filter.dataset = try requireNext(args, "--dataset");
        } else if (std.mem.eql(u8, arg, "--limit")) {
            filter.limit = try parseRequiredUsize(args, "--limit");
        } else {
            return error.InvalidArgument;
        }
    }

    return .{
        .common = .{ .runtime = try resolveRuntimeConfig(allocator, overrides) },
        .filter = filter,
    };
}

fn parseRunDetailArgs(allocator: std.mem.Allocator, args: *ArgCursor) !struct {
    common: struct { runtime: RuntimeConfig },
    run_id: []const u8,
} {
    const run_id = args.next() orelse return error.MissingArgument;
    var overrides = RuntimeOverrides{};

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        return error.InvalidArgument;
    }

    return .{
        .common = .{ .runtime = try resolveRuntimeConfig(allocator, overrides) },
        .run_id = run_id,
    };
}

fn parseSpansArgs(allocator: std.mem.Allocator, args: *ArgCursor) !struct {
    common: struct { runtime: RuntimeConfig },
    filter: domain.SpanFilter,
} {
    var overrides = RuntimeOverrides{};
    var filter = domain.SpanFilter{};

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        if (std.mem.eql(u8, arg, "--run-id")) {
            filter.run_id = try requireNext(args, "--run-id");
        } else if (std.mem.eql(u8, arg, "--trace-id")) {
            filter.trace_id = try requireNext(args, "--trace-id");
        } else if (std.mem.eql(u8, arg, "--source")) {
            filter.source = try requireNext(args, "--source");
        } else if (std.mem.eql(u8, arg, "--operation")) {
            filter.operation = try requireNext(args, "--operation");
        } else if (std.mem.eql(u8, arg, "--status")) {
            filter.status = try requireNext(args, "--status");
        } else if (std.mem.eql(u8, arg, "--model")) {
            filter.model = try requireNext(args, "--model");
        } else if (std.mem.eql(u8, arg, "--tool-name")) {
            filter.tool_name = try requireNext(args, "--tool-name");
        } else if (std.mem.eql(u8, arg, "--task-id")) {
            filter.task_id = try requireNext(args, "--task-id");
        } else if (std.mem.eql(u8, arg, "--session-id")) {
            filter.session_id = try requireNext(args, "--session-id");
        } else if (std.mem.eql(u8, arg, "--agent-id")) {
            filter.agent_id = try requireNext(args, "--agent-id");
        } else if (std.mem.eql(u8, arg, "--limit")) {
            filter.limit = try parseRequiredUsize(args, "--limit");
        } else {
            return error.InvalidArgument;
        }
    }

    return .{
        .common = .{ .runtime = try resolveRuntimeConfig(allocator, overrides) },
        .filter = filter,
    };
}

fn parseEvalsArgs(allocator: std.mem.Allocator, args: *ArgCursor) !struct {
    common: struct { runtime: RuntimeConfig },
    filter: domain.EvalFilter,
} {
    var overrides = RuntimeOverrides{};
    var filter = domain.EvalFilter{};

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        if (std.mem.eql(u8, arg, "--run-id")) {
            filter.run_id = try requireNext(args, "--run-id");
        } else if (std.mem.eql(u8, arg, "--verdict")) {
            filter.verdict = try requireNext(args, "--verdict");
        } else if (std.mem.eql(u8, arg, "--eval-key")) {
            filter.eval_key = try requireNext(args, "--eval-key");
        } else if (std.mem.eql(u8, arg, "--scorer")) {
            filter.scorer = try requireNext(args, "--scorer");
        } else if (std.mem.eql(u8, arg, "--dataset")) {
            filter.dataset = try requireNext(args, "--dataset");
        } else if (std.mem.eql(u8, arg, "--limit")) {
            filter.limit = try parseRequiredUsize(args, "--limit");
        } else {
            return error.InvalidArgument;
        }
    }

    return .{
        .common = .{ .runtime = try resolveRuntimeConfig(allocator, overrides) },
        .filter = filter,
    };
}

fn parseJsonIngestArgs(allocator: std.mem.Allocator, args: *ArgCursor) !struct {
    common: struct { runtime: RuntimeConfig },
    json_payload: []const u8,
} {
    var overrides = RuntimeOverrides{};
    var json_payload: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        if (std.mem.eql(u8, arg, "--json")) {
            json_payload = try requireNext(args, "--json");
        } else {
            return error.InvalidArgument;
        }
    }

    return .{
        .common = .{ .runtime = try resolveRuntimeConfig(allocator, overrides) },
        .json_payload = json_payload orelse return error.MissingArgument,
    };
}

fn maybeParseRuntimeFlag(
    args: *ArgCursor,
    overrides: *RuntimeOverrides,
    arg: []const u8,
    allow_port_and_host: bool,
) !bool {
    if (allow_port_and_host and std.mem.eql(u8, arg, "--host")) {
        overrides.host = try requireNext(args, "--host");
        return true;
    }
    if (allow_port_and_host and std.mem.eql(u8, arg, "--port")) {
        overrides.port = try parseRequiredU16(args, "--port");
        return true;
    }
    if (std.mem.eql(u8, arg, "--data-dir")) {
        overrides.data_dir = try requireNext(args, "--data-dir");
        return true;
    }
    if (std.mem.eql(u8, arg, "--token")) {
        overrides.token = try requireNext(args, "--token");
        return true;
    }
    if (std.mem.eql(u8, arg, "--config")) {
        overrides.config_path = try requireNext(args, "--config");
        return true;
    }
    return false;
}

fn resolveRuntimeConfig(allocator: std.mem.Allocator, overrides: RuntimeOverrides) !RuntimeConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const cfg_path = try config.resolveConfigPath(arena.allocator(), overrides.config_path);
    var cfg = try config.loadFromFile(arena.allocator(), cfg_path);
    try config.resolveRelativePaths(arena.allocator(), cfg_path, &cfg);

    const host = try allocator.dupe(u8, overrides.host orelse cfg.host);
    const data_dir = try allocator.dupe(u8, overrides.data_dir orelse cfg.data_dir);
    const api_token = if (overrides.token orelse cfg.api_token) |token|
        try allocator.dupe(u8, token)
    else
        null;

    return .{
        .host = host,
        .port = overrides.port orelse cfg.port,
        .data_dir = data_dir,
        .api_token = api_token,
    };
}

fn parseRequiredU16(args: *ArgCursor, flag: []const u8) !u16 {
    const value = try requireNext(args, flag);
    return std.fmt.parseInt(u16, value, 10);
}

fn parseRequiredUsize(args: *ArgCursor, flag: []const u8) !usize {
    const value = try requireNext(args, flag);
    return std.fmt.parseInt(usize, value, 10);
}

fn requireNext(args: *ArgCursor, flag: []const u8) ![]const u8 {
    return args.next() orelse {
        std.debug.print("missing value for {s}\n", .{flag});
        return error.MissingArgument;
    };
}

fn writeJsonToStdout(allocator: std.mem.Allocator, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(body);

    const stdout = std_compat.fs.File.stdout();
    try stdout.writeAll(body);
    try stdout.writeAll("\n");
}

fn printUsage() void {
    std.debug.print(
        \\nullwatch v{s}
        \\
        \\Usage:
        \\  nullwatch serve [--host IP] [--port N] [--data-dir PATH] [--config PATH] [--token TOKEN]
        \\  nullwatch summary [--data-dir PATH] [--config PATH]
        \\  nullwatch runs [--run-id ID] [--source SRC] [--operation OP] [--status STATUS] [--model MODEL] [--tool-name NAME] [--verdict VERDICT] [--dataset NAME] [--limit N]
        \\  nullwatch run <run-id> [--data-dir PATH] [--config PATH]
        \\  nullwatch spans [--run-id ID] [--trace-id ID] [--source SRC] [--operation OP] [--status STATUS] [--model MODEL] [--tool-name NAME] [--task-id ID] [--session-id ID] [--agent-id ID] [--limit N]
        \\  nullwatch evals [--run-id ID] [--verdict VERDICT] [--eval-key KEY] [--scorer NAME] [--dataset NAME] [--limit N]
        \\  nullwatch ingest-span --json '<payload>' [--data-dir PATH] [--config PATH]
        \\  nullwatch ingest-eval --json '<payload>' [--data-dir PATH] [--config PATH]
        \\  nullwatch demo-seed [--data-dir PATH] [--config PATH]
        \\  nullwatch --export-manifest
        \\  nullwatch --from-json '<wizard answers json>'
        \\  nullwatch version
        \\
        \\HTTP API:
        \\  GET  /health
        \\  GET  /v1/capabilities
        \\  GET  /v1/summary
        \\  GET  /v1/spans
        \\  POST /v1/spans
        \\  POST /v1/spans/bulk
        \\  GET  /v1/evals
        \\  POST /v1/evals
        \\  POST /v1/evals/bulk
        \\  GET  /v1/runs
        \\  GET  /v1/runs/<run-id>
        \\  POST /v1/traces
        \\  POST /otlp/v1/traces
        \\
    ,
        .{version.string},
    );
}

test {
    _ = api;
    _ = config;
    _ = demo_seed;
    _ = domain;
    _ = Store;
    _ = @import("export_manifest.zig");
    _ = @import("from_json.zig");
}
