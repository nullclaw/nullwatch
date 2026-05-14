const std = @import("std");
const shared = @import("shared.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const path = struct {
    pub const basename = std.fs.path.basename;
    pub const delimiter = std.fs.path.delimiter;
    pub const dirname = std.fs.path.dirname;
    pub const extension = std.fs.path.extension;
    pub const isAbsolute = std.fs.path.isAbsolute;
    pub const isSep = std.fs.path.isSep;
    pub const join = std.fs.path.join;
    pub const sep = std.fs.path.sep;
    pub const sep_str = std.fs.path.sep_str;
};

pub const File = struct {
    handle: Io.File.Handle,
    flags: Io.File.Flags,

    pub const Reader = Io.File.Reader;
    pub const Writer = Io.File.Writer;
    pub const Mode = if (@import("builtin").os.tag == .windows) u32 else std.posix.mode_t;
    pub const Stat = struct {
        inode: Io.File.INode,
        nlink: Io.File.NLink,
        size: u64,
        mode: Mode,
        kind: Io.File.Kind,
        atime: ?i128,
        mtime: i128,
        ctime: i128,
        block_size: Io.File.BlockSize,
    };

    pub fn wrap(inner: Io.File) File {
        return .{
            .handle = inner.handle,
            .flags = inner.flags,
        };
    }

    pub fn toInner(self: File) Io.File {
        return .{
            .handle = self.handle,
            .flags = self.flags,
        };
    }

    fn convertStat(inner: Io.File.Stat) Stat {
        return .{
            .inode = inner.inode,
            .nlink = inner.nlink,
            .size = inner.size,
            .mode = if (@hasDecl(@TypeOf(inner.permissions), "toMode")) inner.permissions.toMode() else 0,
            .kind = inner.kind,
            .atime = if (inner.atime) |ts| ts.nanoseconds else null,
            .mtime = inner.mtime.nanoseconds,
            .ctime = inner.ctime.nanoseconds,
            .block_size = inner.block_size,
        };
    }

    pub fn stdout() File {
        return wrap(Io.File.stdout());
    }

    pub fn stderr() File {
        return wrap(Io.File.stderr());
    }

    pub fn stdin() File {
        return wrap(Io.File.stdin());
    }

    pub fn close(self: File) void {
        self.toInner().close(shared.io());
    }

    pub fn stat(self: File) Io.File.StatError!Stat {
        return convertStat(try self.toInner().stat(shared.io()));
    }

    pub fn seekTo(self: File, offset: u64) Io.File.SeekError!void {
        try shared.io().vtable.fileSeekTo(shared.io().userdata, self.toInner(), offset);
    }

    pub fn seekFromEnd(self: File, offset: i64) !void {
        const file_stat = try self.stat();
        const end_offset = @as(i128, @intCast(file_stat.size)) + offset;
        if (end_offset < 0) return error.Unseekable;
        try self.seekTo(@intCast(end_offset));
    }

    pub fn writer(self: File, buffer: []u8) Writer {
        return self.toInner().writer(shared.io(), buffer);
    }

    pub fn reader(self: File, buffer: []u8) Reader {
        return self.toInner().reader(shared.io(), buffer);
    }

    pub fn read(self: File, buffer: []u8) Io.File.ReadStreamingError!usize {
        return self.toInner().readStreaming(shared.io(), &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => |e| return e,
        };
    }

    pub fn readAll(self: File, buffer: []u8) Io.File.ReadStreamingError!usize {
        var filled: usize = 0;
        while (filled < buffer.len) {
            const amt = try self.read(buffer[filled..]);
            if (amt == 0) break;
            filled += amt;
        }
        return filled;
    }

    pub fn writeAll(self: File, bytes: []const u8) Io.File.Writer.Error!void {
        try self.toInner().writeStreamingAll(shared.io(), bytes);
    }

    pub fn readToEndAlloc(self: File, allocator: Allocator, max_bytes: usize) ![]u8 {
        var stream_buf: [4096]u8 = undefined;
        var file_reader = self.toInner().readerStreaming(shared.io(), &stream_buf);
        return try file_reader.interface.allocRemaining(allocator, .limited(max_bytes));
    }
};

pub const Dir = struct {
    handle: Io.Dir.Handle,

    pub const OpenDirOptions = Io.Dir.OpenOptions;
    pub const OpenFileOptions = Io.Dir.OpenFileOptions;
    pub const CreateFileOptions = Io.Dir.CreateFileOptions;
    pub const WriteFileOptions = Io.Dir.WriteFileOptions;
    pub const AccessOptions = Io.Dir.AccessOptions;
    pub const CopyFileOptions = Io.Dir.CopyFileOptions;
    pub const SymLinkFlags = Io.Dir.SymLinkFlags;
    pub const Entry = Io.Dir.Entry;
    pub const Iterator = struct {
        inner: Io.Dir.Iterator,

        pub fn next(self: *Iterator) Io.Dir.Iterator.Error!?Entry {
            return self.inner.next(shared.io());
        }
    };

    pub fn wrap(inner: Io.Dir) Dir {
        return .{ .handle = inner.handle };
    }

    fn toInner(self: Dir) Io.Dir {
        return .{ .handle = self.handle };
    }

    pub fn cwd() Dir {
        return wrap(Io.Dir.cwd());
    }

    pub fn close(self: Dir) void {
        self.toInner().close(shared.io());
    }

    pub fn iterate(self: Dir) Iterator {
        return .{ .inner = self.toInner().iterate() };
    }

    pub fn openDir(self: Dir, sub_path: []const u8, options: OpenDirOptions) Io.Dir.OpenError!Dir {
        return wrap(try self.toInner().openDir(shared.io(), sub_path, options));
    }

    pub fn openFile(self: Dir, sub_path: []const u8, options: OpenFileOptions) Io.File.OpenError!File {
        return File.wrap(try self.toInner().openFile(shared.io(), sub_path, options));
    }

    pub fn createFile(self: Dir, sub_path: []const u8, options: CreateFileOptions) Io.File.OpenError!File {
        return File.wrap(try self.toInner().createFile(shared.io(), sub_path, options));
    }

    pub fn writeFile(self: Dir, options: WriteFileOptions) Io.Dir.WriteFileError!void {
        try self.toInner().writeFile(shared.io(), options);
    }

    pub fn readFileAlloc(self: Dir, allocator: Allocator, sub_path: []const u8, max_bytes: usize) ![]u8 {
        return try self.toInner().readFileAlloc(shared.io(), sub_path, allocator, .limited(max_bytes));
    }

    pub fn access(self: Dir, sub_path: []const u8, options: AccessOptions) Io.Dir.AccessError!void {
        try self.toInner().access(shared.io(), sub_path, options);
    }

    pub fn makeDir(self: Dir, sub_path: []const u8) Io.Dir.CreateDirError!void {
        try self.toInner().createDir(shared.io(), sub_path, .default_dir);
    }

    pub fn deleteFile(self: Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
        try self.toInner().deleteFile(shared.io(), sub_path);
    }

    pub fn deleteTree(self: Dir, sub_path: []const u8) Io.Dir.DeleteTreeError!void {
        try self.toInner().deleteTree(shared.io(), sub_path);
    }

    pub fn rename(self: Dir, old_sub_path: []const u8, new_sub_path: []const u8) Io.Dir.RenameError!void {
        try self.toInner().rename(old_sub_path, self.toInner(), new_sub_path, shared.io());
    }

    pub fn realpathAlloc(self: Dir, allocator: Allocator, sub_path: []const u8) Io.Dir.RealPathFileAllocError![]u8 {
        const path_z = try self.toInner().realPathFileAlloc(shared.io(), sub_path, allocator);
        defer allocator.free(path_z);
        return try allocator.dupe(u8, path_z);
    }

    pub fn statFile(self: Dir, sub_path: []const u8) !File.Stat {
        return File.convertStat(try self.toInner().statFile(shared.io(), sub_path, .{}));
    }

    pub fn makePath(self: Dir, sub_path: []const u8) !void {
        if (sub_path.len == 0) return;
        if (path.isAbsolute(sub_path)) {
            try makePathAbsolute(sub_path);
            return;
        }

        var cursor = self;
        var opened: ?Dir = null;
        defer if (opened) |dir| dir.close();

        var index: usize = 0;
        while (index < sub_path.len) {
            while (index < sub_path.len and path.isSep(sub_path[index])) : (index += 1) {}
            if (index >= sub_path.len) break;

            const start = index;
            while (index < sub_path.len and !path.isSep(sub_path[index])) : (index += 1) {}
            const component = sub_path[start..index];
            if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
            if (std.mem.eql(u8, component, "..")) return error.BadPathName;

            cursor.makeDir(component) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };

            const next = try cursor.openDir(component, .{});
            if (opened) |dir| dir.close();
            opened = next;
            cursor = next;
        }
    }
};

pub fn cwd() Dir {
    return Dir.cwd();
}

pub fn openDirAbsolute(absolute_path: []const u8, options: Dir.OpenDirOptions) Io.Dir.OpenError!Dir {
    return Dir.wrap(try Io.Dir.openDirAbsolute(shared.io(), absolute_path, options));
}

pub fn openFileAbsolute(absolute_path: []const u8, options: Dir.OpenFileOptions) Io.File.OpenError!File {
    return File.wrap(try Io.Dir.openFileAbsolute(shared.io(), absolute_path, options));
}

pub fn createFileAbsolute(absolute_path: []const u8, options: Dir.CreateFileOptions) Io.File.OpenError!File {
    return File.wrap(try Io.Dir.createFileAbsolute(shared.io(), absolute_path, options));
}

pub fn accessAbsolute(absolute_path: []const u8, options: Dir.AccessOptions) Io.Dir.AccessError!void {
    try Io.Dir.accessAbsolute(shared.io(), absolute_path, options);
}

pub fn makeDirAbsolute(absolute_path: []const u8) Io.Dir.CreateDirError!void {
    try Io.Dir.createDirAbsolute(shared.io(), absolute_path, .default_dir);
}

pub fn makePathAbsolute(absolute_path: []const u8) Io.Dir.CreateDirPathError!void {
    try Io.Dir.createDirPath(Io.Dir.cwd(), shared.io(), absolute_path);
}

pub fn deleteFileAbsolute(absolute_path: []const u8) Io.Dir.DeleteFileError!void {
    try Io.Dir.deleteFileAbsolute(shared.io(), absolute_path);
}

pub fn deleteTreeAbsolute(absolute_path: []const u8) (Io.Dir.DeleteTreeError || error{FileNotFound})!void {
    const dir_path = path.dirname(absolute_path) orelse return error.FileNotFound;
    const base_name = path.basename(absolute_path);
    var dir = try openDirAbsolute(dir_path, .{});
    defer dir.close();
    try dir.deleteTree(base_name);
}

pub fn renameAbsolute(old_path: []const u8, new_path: []const u8) Io.Dir.RenameError!void {
    try Io.Dir.renameAbsolute(old_path, new_path, shared.io());
}

pub fn realpathAlloc(allocator: Allocator, file_path: []const u8) ![]u8 {
    if (path.isAbsolute(file_path)) {
        const path_z = try Io.Dir.realPathFileAbsoluteAlloc(shared.io(), file_path, allocator);
        defer allocator.free(path_z);
        return try allocator.dupe(u8, path_z);
    }
    return try cwd().realpathAlloc(allocator, file_path);
}

test "makePathAbsolute creates nested absolute directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir = Dir.wrap(tmp.dir);
    const root = try tmp_dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const nested = try path.join(std.testing.allocator, &.{ root, "nested", "path" });
    defer std.testing.allocator.free(nested);

    try makePathAbsolute(nested);
    try accessAbsolute(nested, .{});

    try makePathAbsolute(nested);
}
