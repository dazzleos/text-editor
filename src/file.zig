//! The file being edited: read once, and saved again as it changes (a
//! moment after typing stops, and when the window closes). Saving writes
//! a new file beside it (".<name>.saving") and puts it in the old one's
//! place, so a file is never left half written; it keeps the old one's
//! permissions.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

/// The biggest file it edits.
pub const max_size = 1 << 20;

/// How long after typing stops the file is saved.
pub const save_delay_ns = 1 * std.time.ns_per_s;

pub const OpenError = error{ NotFound, AccessDenied, TooBig, NotText, Unexpected };

pub fn describeOpenError(err: OpenError) []const u8 {
    return switch (err) {
        error.NotFound => "The file is not there any more",
        error.AccessDenied => "You are not allowed to read this file",
        error.TooBig => "The file is too big to edit here (the most is 1 MB)",
        error.NotText => "The file is not text, so it cannot be edited here",
        error.Unexpected => "The file cannot be read",
    };
}

/// The file's text (in `gpa`).
pub fn read(gpa: std.mem.Allocator, path: [:0]const u8) OpenError![]u8 {
    const data = sys.readFileAlloc(gpa, path, max_size + 1) catch |err| return switch (err) {
        error.NotFound => error.NotFound,
        error.AccessDenied => error.AccessDenied,
        // Bigger than asked for.
        error.OutOfMemory => error.TooBig,
        else => error.Unexpected,
    };
    errdefer gpa.free(data);
    if (data.len > max_size) return error.TooBig;
    if (!std.unicode.utf8ValidateSlice(data) or std.mem.indexOfScalar(u8, data, 0) != null) return error.NotText;
    return data;
}

pub const SaveError = error{ AccessDenied, NoSpace, Unexpected };

pub fn describeSaveError(err: SaveError) []const u8 {
    return switch (err) {
        error.AccessDenied => "you are not allowed to change it",
        error.NoSpace => "there is no space left",
        error.Unexpected => "it could not be written",
    };
}

/// Writes `text` to the file at `path` (whole, or not at all).
pub fn save(path: []const u8, text: []const u8) SaveError!void {
    var tmp_buf: [4096]u8 = undefined;
    var path_buf: [4096]u8 = undefined;
    const dir = std.fs.path.dirname(path) orelse ".";
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}/.{s}.saving", .{ dir, std.fs.path.basename(path) }) catch return error.Unexpected;
    const dest = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.Unexpected;
    // The permissions it has (a new file's otherwise).
    var stx: linux.Statx = undefined;
    const mode: u32 = if (linux.errno(linux.statx(linux.AT.FDCWD, dest, 0, .{ .MODE = true }, &stx)) == .SUCCESS) stx.mode & 0o777 else 0o644;
    const rc = linux.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, mode);
    if (linux.errno(rc) != .SUCCESS) return errorFrom(linux.errno(rc));
    const fd: linux.fd_t = @intCast(rc);
    var done = false;
    defer if (!done) {
        _ = linux.unlink(tmp);
    };
    {
        defer sys.close(fd);
        var at: usize = 0;
        while (at < text.len) {
            const w = linux.write(fd, text[at..].ptr, text.len - at);
            switch (linux.errno(w)) {
                .SUCCESS => at += w,
                .INTR => {},
                else => |e| return errorFrom(e),
            }
        }
        _ = linux.fchmod(fd, mode);
        if (linux.errno(linux.fsync(fd)) != .SUCCESS) return error.Unexpected;
    }
    if (linux.errno(linux.rename(tmp, dest)) != .SUCCESS) return error.Unexpected;
    done = true;
}

fn errorFrom(e: linux.E) SaveError {
    return switch (e) {
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NOSPC, .DQUOT => error.NoSpace,
        else => error.Unexpected,
    };
}

pub const user_dir = "/data/user";
pub const recent_file = "/data/user/.recent-text-files";
pub const max_recent = 10;

/// A numbered name for a new text file in `dir` ("Note 1.txt", "Note 2.txt", …).
pub fn defaultNewName(buf: []u8, dir: []const u8) []const u8 {
    if (sys.files.numberedName(buf, dir, "Note", "txt")) |full| {
        return std.fs.path.basename(full);
    }
    return "Note 1.txt";
}

pub const MakeError = error{ EmptyName, BadName, Exists, AccessDenied, NoSpace, Unexpected };

pub fn describeMakeError(err: MakeError) []const u8 {
    return switch (err) {
        error.EmptyName => "give the new file a name",
        error.BadName => "a file name cannot have / in it",
        error.Exists => "there is already something with that name",
        error.AccessDenied => "you are not allowed to make a file here",
        error.NoSpace => "there is no space left",
        error.Unexpected => "it could not be made",
    };
}

/// Makes an empty text file in `dir` named `raw_name` (adding `.txt` if it
/// has no extension) and returns its path in `buf`.
pub fn makeNewFile(buf: []u8, dir: []const u8, raw_name: []const u8) MakeError![:0]const u8 {
    const trimmed = std.mem.trim(u8, raw_name, " ");
    if (trimmed.len == 0) return error.EmptyName;
    if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..")) return error.BadName;
    if (std.mem.indexOfAny(u8, trimmed, "/\x00") != null) return error.BadName;
    const dot = std.mem.lastIndexOfScalar(u8, trimmed, '.');
    const has_ext = if (dot) |d| d > 0 and d + 1 < trimmed.len else false;
    const suffix = if (has_ext) "" else ".txt";
    const path = std.fmt.bufPrintZ(buf, "{s}/{s}{s}", .{ dir, trimmed, suffix }) catch return error.Unexpected;
    sys.files.writeNew(path, "") catch |err| return switch (err) {
        error.Exists => error.Exists,
        error.AccessDenied => error.AccessDenied,
        else => error.Unexpected,
    };
    return path;
}

/// Recently opened text files, newest first, kept in `recent_file`.
pub const Recent = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList([:0]u8) = .empty,

    pub fn load(gpa: std.mem.Allocator, list_path: [:0]const u8) Recent {
        var r: Recent = .{ .gpa = gpa };
        const data = sys.readFileAlloc(gpa, list_path, 64 * 1024) catch return r;
        defer gpa.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or r.items.items.len >= max_recent) continue;
            if (r.indexOf(line) != null) continue;
            const copy = gpa.dupeZ(u8, line) catch break;
            if (linux.errno(linux.access(copy.ptr, linux.F_OK)) != .SUCCESS) {
                gpa.free(copy);
                continue;
            }
            r.items.append(gpa, copy) catch {
                gpa.free(copy);
                break;
            };
        }
        return r;
    }

    pub fn deinit(self: *Recent) void {
        for (self.items.items) |p| self.gpa.free(p);
        self.items.deinit(self.gpa);
    }

    pub fn slice(self: *const Recent) []const [:0]const u8 {
        return self.items.items;
    }

    fn indexOf(self: *const Recent, path: []const u8) ?usize {
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, path)) return i;
        }
        return null;
    }

    /// Puts `file_path` at the top of the list and writes `list_path`.
    pub fn record(self: *Recent, list_path: []const u8, file_path: []const u8) void {
        if (self.indexOf(file_path)) |i| {
            const existing = self.items.orderedRemove(i);
            self.items.insert(self.gpa, 0, existing) catch {
                self.gpa.free(existing);
                return;
            };
        } else {
            const copy = self.gpa.dupeZ(u8, file_path) catch return;
            self.items.insert(self.gpa, 0, copy) catch {
                self.gpa.free(copy);
                return;
            };
            while (self.items.items.len > max_recent) {
                const dropped = self.items.pop().?;
                self.gpa.free(dropped);
            }
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        for (self.items.items) |p| {
            out.appendSlice(self.gpa, p) catch return;
            out.append(self.gpa, '\n') catch return;
        }
        save(list_path, out.items) catch {};
    }
};

const testing = std.testing;

test "reading and saving a text file, whole" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/dazzle-text-editor-test-{d}", .{linux.getpid()});
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/notes.txt", .{dir});
    try sys.files.writeNew(path, "hello\n");
    _ = linux.chmod(path, 0o600);
    const text = try read(testing.allocator, path);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hello\n", text);
    try save(path, "héllo again\n");
    const again = try read(testing.allocator, path);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings("héllo again\n", again);
    // Its permissions kept, and nothing left beside it.
    var stx: linux.Statx = undefined;
    _ = linux.statx(linux.AT.FDCWD, path, 0, .{ .MODE = true }, &stx);
    try testing.expectEqual(@as(u32, 0o600), stx.mode & 0o777);
    var tmp_buf: [128]u8 = undefined;
    try testing.expect(linux.errno(linux.access(try std.fmt.bufPrintZ(&tmp_buf, "{s}/.notes.txt.saving", .{dir}), linux.F_OK)) == .NOENT);

    // Not text, or not there.
    const bin = try std.fmt.bufPrintZ(&tmp_buf, "{s}/data.bin", .{dir});
    try sys.files.writeNew(bin, "\x00\x01\xff");
    try testing.expectError(error.NotText, read(testing.allocator, bin));
    try testing.expectError(error.NotFound, read(testing.allocator, try std.fmt.bufPrintZ(&tmp_buf, "{s}/none.txt", .{dir})));
    // A folder that is not there.
    try testing.expectError(error.Unexpected, save("/nonexistent/notes.txt", "x"));
}

test "making a new file with a pre-populated name, and remembering recent files" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/dazzle-text-editor-recent-{d}", .{linux.getpid()});
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);

    var name_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Note 1.txt", defaultNewName(&name_buf, dir));

    var path1_buf: [256]u8 = undefined;
    const p1 = try makeNewFile(&path1_buf, dir, defaultNewName(&name_buf, dir));
    try testing.expect(std.mem.endsWith(u8, p1, "/Note 1.txt"));
    try testing.expectEqualStrings("Note 2.txt", defaultNewName(&name_buf, dir));

    // Without an extension, .txt is added; existing names and bad names fail.
    var path2_buf: [256]u8 = undefined;
    const p2 = try makeNewFile(&path2_buf, dir, "todo");
    try testing.expect(std.mem.endsWith(u8, p2, "/todo.txt"));
    try testing.expectError(error.Exists, makeNewFile(&name_buf, dir, "todo.txt"));
    try testing.expectError(error.EmptyName, makeNewFile(&name_buf, dir, "   "));
    try testing.expectError(error.BadName, makeNewFile(&name_buf, dir, "a/b"));

    // Recent files: newest first, deduplicated, and missing files skipped on load.
    var list_buf: [256]u8 = undefined;
    const list_path = try std.fmt.bufPrintZ(&list_buf, "{s}/.recent-text-files", .{dir});
    var r = Recent.load(testing.allocator, list_path);
    try testing.expectEqual(@as(usize, 0), r.slice().len);
    r.record(list_path, p1);
    r.record(list_path, p2);
    r.record(list_path, p1);
    try testing.expectEqual(@as(usize, 2), r.slice().len);
    try testing.expectEqualStrings(p1, r.slice()[0]);
    try testing.expectEqualStrings(p2, r.slice()[1]);
    r.deinit();

    _ = linux.unlink(p2);
    var r2 = Recent.load(testing.allocator, list_path);
    defer r2.deinit();
    try testing.expectEqual(@as(usize, 1), r2.slice().len);
    try testing.expectEqualStrings(p1, r2.slice()[0]);
}

