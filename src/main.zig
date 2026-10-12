//! Dazzle's text editor: edits a text file, saving it as it goes (a
//! moment after typing stops, and when the window closes; see file.zig).
//! Files starts it with the file to edit (its Edit button, and New text
//! file); it says it opens plain text in dazzle-text-editor.handles,
//! beside it.
//!
//!     dazzle-text-editor [file]
//!
//! JSON, Python and Zig are coloured (see syntax.zig). Without a file it
//! says how to open one. It runs until its window is closed.

const std = @import("std");
const sys = @import("sys");
const locale = @import("locale");
const ui = @import("ui");
const file = @import("file.zig");
const view = @import("view.zig");
const syntax = @import("syntax.zig");

const print = sys.print;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    const path: ?[:0]const u8 = if (args.next()) |p| std.mem.span(p.ptr) else null;
    run(init, path) catch |err| {
        print(sys.log_error ++ "dazzle-text-editor: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// Notes a change to the text, for saving it in a moment.
const Changes = struct {
    at: ?u64 = null,

    fn changed(c: *Changes) void {
        c.at = sys.nowNs();
    }
};

fn run(init: std.process.Init.Minimal, path: ?[:0]const u8) !void {
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    const a = try ui.App.open(gpa, init.environ, .{
        .title = if (path) |p| std.fs.path.basename(p) else "Text Editor",
        .app_id = "dazzle-text-editor",
        .size = view.open_size,
        .min_size = view.min_size,
    });
    defer a.close();

    // The file's text, if it can be edited.
    var doc: ?ui.TextDocument = null;
    var message: []const u8 = "";
    if (path) |p| {
        if (file.read(gpa, p)) |text| {
            defer gpa.free(text);
            doc = try ui.TextDocument.init(gpa, text);
        } else |err| message = file.describeOpenError(err);
    }
    defer if (doc) |*d| d.deinit();
    // Code is coloured, by the file's name.
    const highlighter = if (path) |p| syntax.highlighter(syntax.languageOf(std.fs.path.basename(p))) else null;
    var saved_version: u64 = 0;
    var save_failure: ?[]const u8 = null;
    var changes: Changes = .{};
    // What is not saved yet is when the window closes.
    defer saveNow(path, doc, &saved_version, &save_failure);

    while (true) {
        // Wait for input, or until it is time to save.
        var timeout: u64 = 60 * std.time.ns_per_s;
        if (changes.at) |at| timeout = @min(timeout, (at + file.save_delay_ns) -| sys.nowNs() + std.time.ns_per_ms);
        if (!try a.step(timeout)) return;
        const now = sys.nowNs();
        a.takeInput();
        // Saved a moment after typing stops.
        if (changes.at) |at| if (now >= at + file.save_delay_ns) {
            changes.at = null;
            saveNow(path, doc, &saved_version, &save_failure);
            a.dirty = true;
        };

        const d: ?*ui.TextDocument = if (doc) |*dd| dd else null;
        const saved: view.Saved = if (save_failure) |why| .{ .failed = why } else if (d != null and d.?.version != saved_version) .changed else .saved;
        try a.draw(now, view.Editor{
            .path = path,
            .doc = d,
            .message = message,
            .highlighter = highlighter,
            .saved = saved,
            .on_changed = .of(&changes, Changes.changed),
        });
    }
}

/// Saves the text if it changed since it was last saved.
fn saveNow(path: ?[:0]const u8, doc: ?ui.TextDocument, saved_version: *u64, failure: *?[]const u8) void {
    const p = path orelse return;
    const d = doc orelse return;
    if (d.version == saved_version.*) return;
    if (file.save(p, d.text())) {
        saved_version.* = d.version;
        failure.* = null;
    } else |err| {
        failure.* = file.describeSaveError(err);
        print(sys.log_warning ++ "dazzle-text-editor: cannot save {s}: {s}\n", .{ p, @errorName(err) });
    }
}

test {
    _ = file;
    _ = view;
    _ = syntax;
}
