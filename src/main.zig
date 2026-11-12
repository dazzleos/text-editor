//! Dazzle's text editor: edits a text file, saving it as it goes (a
//! moment after typing stops, and when the window closes; see file.zig).
//! Files starts it with the file to edit (its Edit button, and New text
//! file); it says it opens plain text in dazzle-text-editor.handles,
//! beside it.
//!
//!     dazzle-text-editor [file]
//!
//! JSON, Python and Zig are coloured (see syntax.zig). Without a file it
//! shows a "New File" button with a pre-populated name and a list of
//! recently opened files below it. It runs until its window is closed.

const std = @import("std");
const sys = @import("sys");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const file = @import("file.zig");
const view = @import("view.zig");
const syntax = @import("syntax.zig");

const print = sys.print;

pub fn main(init: std.process.Init) u8 {
    sys.logToKmsgIfStderr();
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const path: ?[:0]const u8 = if (args.next()) |p| std.mem.span(p.ptr) else null;
    run(init, path) catch |err| {
        print(sys.log_error ++ "dazzle-text-editor: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init, initial_path: ?[:0]const u8) !void {
    const gpa = std.heap.page_allocator;
    var host: kete_vc4.Host = undefined;
    try host.init(gpa, init.io, init.minimal.environ, .{ .app_id = "dazzle-text-editor" });
    defer host.deinit();

    var e: Editor = .{ .gpa = gpa, .recent = .load(gpa, file.recent_file) };
    defer e.deinit();
    e.default_name = file.defaultNewName(&e.default_buf, file.user_dir);
    e.start_name = .init(e.default_name);
    if (initial_path) |p| e.open(p);
    // What is not saved yet is when the window closes.
    defer e.saveNow();

    const root: Root = .{ .e = &e };
    e.window = try host.app.openWindow(.{
        .title = e.title(),
        .root = .of(&root),
        .size = view.open_size,
        .min_size = view.min_size,
        .on_close_request = .close,
    });

    while (true) {
        // Wait for something to do, or until it is time to save.
        var timeout: u64 = std.math.maxInt(u64);
        if (e.changed_at) |at| timeout = (at + file.save_delay_ns) -| sys.nowNs() + std.time.ns_per_ms;
        if (!try host.app.step(timeout)) return;
        // Saved a moment after typing stops.
        if (e.changed_at) |at| if (sys.nowNs() >= at + file.save_delay_ns) {
            e.changed_at = null;
            e.saveNow();
            e.redraw();
        };
    }
}

/// The window's root: the editor, as it is now.
const Root = struct {
    e: *Editor,

    pub fn build(r: *const Root, cx: *kete.BuildContext) kete.Widget {
        const e = r.e;
        const d: ?*kete.TextDocument = if (e.doc) |*dd| dd else null;
        const saved: view.Saved = if (e.save_failure) |why| .{ .failed = why } else if (d != null and d.?.version != e.saved_version) .changed else .saved;
        return cx.make(view.Editor{
            .path = e.path,
            .doc = d,
            .message = e.message,
            .highlighter = e.highlighter,
            .saved = saved,
            .default_name = e.default_name,
            .recent = e.recent.slice(),
            .on_name_changed = .of(&e.start_name, Name.set),
            .on_new_file = .of(e, Editor.makeFile),
            .on_open_recent = .of(e, Editor.openRecent),
            .on_changed = .of(e, Editor.changed),
        });
    }
};

/// The new file's name, as typed on the start screen.
const Name = struct {
    buf: [kete.TextField.capacity]u8 = undefined,
    len: usize = 0,

    fn init(text: []const u8) Name {
        var n: Name = .{};
        n.set(text);
        return n;
    }

    fn get(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }

    fn set(n: *Name, text: []const u8) void {
        var len = @min(text.len, n.buf.len);
        while (len > 0 and len < text.len and text[len] & 0xc0 == 0x80) len -= 1;
        @memcpy(n.buf[0..len], text[0..len]);
        n.len = len;
    }
};

/// The file being edited (or, with none, the start screen), and whether it
/// is saved.
const Editor = struct {
    gpa: std.mem.Allocator,
    window: ?*kete.App.Window = null,
    recent: file.Recent,
    /// The start screen's name for a new file, pre-populated.
    default_buf: [256]u8 = undefined,
    default_name: []const u8 = "",
    start_name: Name = .{},
    path_buf: [4096]u8 = undefined,
    path: ?[:0]const u8 = null,
    /// The file's text, if it can be edited.
    doc: ?kete.TextDocument = null,
    /// Why it cannot be, or a new file could not be made.
    message: []const u8 = "",
    /// Code is coloured, by the file's name.
    highlighter: ?kete.TextArea.Highlighter = null,
    saved_version: u64 = 0,
    save_failure: ?[]const u8 = null,
    /// When the text last changed, if it is not saved since.
    changed_at: ?u64 = null,

    fn deinit(e: *Editor) void {
        if (e.doc) |*d| d.deinit();
        e.recent.deinit();
    }

    /// The window's title: the file's name.
    fn title(e: *const Editor) []const u8 {
        return if (e.path) |p| std.fs.path.basename(p) else "Text Editor";
    }

    fn redraw(e: *Editor) void {
        if (e.window) |w| w.dirty = true;
    }

    /// Edits the file at `p` (or says why it cannot).
    fn open(e: *Editor, p: []const u8) void {
        const owned = std.mem.printSentinel(&e.path_buf, "{s}", .{p}, 0) catch {
            e.message = file.describeOpenError(error.Unexpected);
            return;
        };
        e.path = owned;
        e.message = "";
        if (file.read(e.gpa, owned)) |text| {
            defer e.gpa.free(text);
            e.edit(kete.TextDocument.init(e.gpa, text));
            e.recent.record(file.recent_file, owned);
        } else |err| e.message = file.describeOpenError(err);
        e.highlighter = syntax.highlighter(syntax.languageOf(std.fs.path.basename(owned)));
        if (e.window) |w| w.setTitle(e.title());
    }

    fn edit(e: *Editor, doc: error{OutOfMemory}!kete.TextDocument) void {
        if (e.doc) |*d| d.deinit();
        e.doc = doc catch null;
        e.saved_version = 0;
        e.save_failure = null;
        e.changed_at = null;
        if (e.doc == null) e.message = file.describeOpenError(error.TooBig);
    }

    /// Makes the new file named on the start screen, and edits it.
    fn makeFile(e: *Editor) void {
        var buf: [4096]u8 = undefined;
        if (file.makeNewFile(&buf, file.user_dir, e.start_name.get())) |created| {
            e.open(created);
        } else |err| {
            e.message = file.describeMakeError(err);
        }
    }

    fn openRecent(e: *Editor, p: [:0]const u8) void {
        e.open(p);
    }

    fn changed(e: *Editor) void {
        e.changed_at = sys.nowNs();
    }

    /// Saves the text if it changed since it was last saved.
    fn saveNow(e: *Editor) void {
        const p = e.path orelse return;
        const d = e.doc orelse return;
        if (d.version == e.saved_version) return;
        if (file.save(p, d.text())) {
            e.saved_version = d.version;
            e.save_failure = null;
        } else |err| {
            e.save_failure = file.describeSaveError(err);
            print(sys.log_warning ++ "dazzle-text-editor: cannot save {s}: {s}\n", .{ p, @errorName(err) });
        }
    }
};

test {
    _ = file;
    _ = view;
    _ = syntax;
}
