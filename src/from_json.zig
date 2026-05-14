const std = @import("std");
const builtin = @import("builtin");
const std_compat = @import("compat.zig");
const config_mod = @import("config.zig");

pub fn run(allocator: std.mem.Allocator, json_str: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        std.debug.print("error: invalid JSON\n", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("error: invalid JSON\n", .{});
        std.process.exit(1);
    }

    const obj = parsed.value.object;
    const host = getString(obj, "host") orelse "127.0.0.1";
    const port = getU16(obj, "port") orelse 7710;
    const data_dir = getString(obj, "data_dir") orelse "data";
    const api_token = getString(obj, "api_token");
    const home = resolveHome(allocator, getString(obj, "home")) catch |err| {
        std.debug.print("error: failed to resolve home: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(home);

    const config_json = try std.json.Stringify.valueAlloc(allocator, .{
        .host = host,
        .port = port,
        .data_dir = data_dir,
        .api_token = api_token,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer allocator.free(config_json);

    try ensureHome(home);
    try writeFileAtHome(allocator, home, "config.json", config_json);

    if (!builtin.is_test) {
        const stdout = std_compat.fs.File.stdout();
        try stdout.writeAll("{\"status\":\"ok\"}\n");
    }
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn getU16(obj: std.json.ObjectMap, key: []const u8) ?u16 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |v| if (v >= 0 and v <= std.math.maxInt(u16)) @intCast(v) else null,
        .string => |v| std.fmt.parseInt(u16, v, 10) catch null,
        else => null,
    };
}

fn ensureHome(home: []const u8) !void {
    if (std.fs.path.isAbsolute(home)) {
        try std_compat.fs.makePathAbsolute(home);
        return;
    }

    try std_compat.fs.cwd().makePath(home);
}

fn writeFileAtHome(allocator: std.mem.Allocator, home: []const u8, name: []const u8, contents: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ home, name });
    defer allocator.free(path);

    if (std.fs.path.isAbsolute(home)) {
        const file = try std_compat.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(contents);
        try file.writeAll("\n");
        return;
    }

    const file = try std_compat.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(contents);
    try file.writeAll("\n");
}

fn resolveHome(allocator: std.mem.Allocator, json_home: ?[]const u8) ![]const u8 {
    if (json_home) |home| return allocator.dupe(u8, home);
    return config_mod.resolveHomeDir(allocator);
}
