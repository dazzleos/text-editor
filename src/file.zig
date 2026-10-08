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
