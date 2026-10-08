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
const font = @import("font");
const vc4 = @import("vc4");
const app = @import("app");
const ui = @import("ui");
const wayland = @import("wayland");
const file = @import("file.zig");
const view = @import("view.zig");
const syntax = @import("syntax.zig");

const print = sys.print;

/// The clear colour: the dark theme's surface.
const background = 0xff141218;

var frame: vc4.render.Frame = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    const path: ?[:0]const u8 = if (args.next()) |p| std.mem.span(p.ptr) else null;
    run(init, path) catch |err| {
        print("dazzle-text-editor: error: {s}\n", .{@errorName(err)});
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
    var dev = vc4.device.openRender() catch |err| {
        print("dazzle-text-editor: no GPU ({s})\n", .{@errorName(err)});
        return err;
    };
    const win = try openWindow(gpa, init, &dev, if (path) |p| std.fs.path.basename(p) else "Text Editor");
    var width = win.width;
    var height = win.height;

    var font_buf: [512]u8 = undefined;
    var f: ?font.Font = blk: {
        const data = sys.readFileAlloc(gpa, sys.fontFile(&font_buf, font.default_font_file), 32 * 1024 * 1024) catch break :blk null;
        break :blk font.Font.init(data) catch null;
    };
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    window_ui.clipboard = .of(&win.clipboard);
    try window_ui.attachGpu(dev);

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

    var controls: app.Controls = .{ .win = win };
    win.setMinSize(view.min_size[0], view.min_size[1]);

    var dirty = true;
    var idle = false;
    var suspended = false;
    while (true) {
        const waited = if (idle) blk: {
            // Wait for input, or until it is time to save.
            var timeout: u64 = if (window_ui.needs_frame and !suspended) 16 * std.time.ns_per_ms else 60 * std.time.ns_per_s;
            if (changes.at) |at| timeout = @min(timeout, (at + file.save_delay_ns) -| sys.nowNs() + std.time.ns_per_ms);
            break :blk win.wait(timeout);
        } else win.poll();
        waited catch |err| {
            if (err == error.ServerError) print("dazzle-text-editor: compositor error: {s}\n", .{win.conn.errorMessage()});
            saveNow(path, doc, &saved_version, &save_failure);
            return err;
        };
        if (win.closed or controls.quit) {
            // What is not saved yet is.
            saveNow(path, doc, &saved_version, &save_failure);
            return;
        }
        if (try win.applyConfigure()) |size| {
            width = size[0];
            height = size[1];
            dirty = true;
        }
        if (win.suspended != suspended) {
            suspended = win.suspended;
            if (suspended) win.releaseSpareBuffers() else dirty = true;
        }
        const now = sys.nowNs();
        window_ui.keyboard = win.layout;
        for (win.takeInput()) |e| switch (e) {
            .motion => |pos| window_ui.pointerMotion(pos),
            .button => |b| window_ui.pointerButton(b.pos, b.code, b.pressed),
            .key => |k| window_ui.keyEvent(k.code, k.pressed),
            .scroll => |sc| window_ui.pointerScroll(sc.pos, sc.dx, sc.dy),
            .leave => window_ui.pointerLeave(),
            .touch_down => |t| window_ui.touchDown(t.id, t.pos),
            .touch_motion => |t| window_ui.touchMotion(t.id, t.pos),
            .touch_up => |id| window_ui.touchUp(id),
            .touch_cancel => window_ui.touchCancel(),
            .relative_motion, .pointer_locked => {},
        };
        // Saved a moment after typing stops.
        if (changes.at) |at| if (now >= at + file.save_delay_ns) {
            changes.at = null;
            saveNow(path, doc, &saved_version, &save_failure);
            dirty = true;
        };

        idle = true;
        if (!suspended and (dirty or window_ui.needs_frame)) {
            dirty = false;
            const d: ?*ui.TextDocument = if (doc) |*dd| dd else null;
            const saved: view.Saved = if (save_failure) |why| .{ .failed = why } else if (d != null and d.?.version != saved_version) .changed else .saved;
            window_ui.fullscreen = win.fullscreen;
            window_ui.frame(width, height, now, view.Editor{
                .path = path,
                .doc = d,
                .message = message,
                .highlighter = highlighter,
                .saved = saved,
                .on_changed = .of(&changes, Changes.changed),
                .on_close = .of(&controls, app.Controls.close),
                .on_maximize = .of(&controls, app.Controls.toggleMaximized),
                .on_drag = .of(&controls, app.Controls.drag),
                .maximized = win.maximized,
            });
            if (window_ui.changed()) {
                idle = false;
                const target = try win.beginFrame();
                const region = window_ui.repaint(win.bufferAge());
                frame.begin(target, .{ .clear = background });
                ui.Ui.limit(&frame, &region);
                try window_ui.render(&frame, win.flusher());
                try win.render(&frame);
                var damage: [ui.damage.Region.max_rects]vc4.render.Viewport = undefined;
                const changed = window_ui.damaged();
                for (changed, damage[0..changed.len]) |r, *v| v.* = .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) };
                try win.showDamaged(damage[0..changed.len]);
            }
        }
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
        print("dazzle-text-editor: cannot save {s}: {s}\n", .{ p, @errorName(err) });
    }
}

fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal, dev: *vc4.Device, title: []const u8) !*app.Window {
    const Environ = std.process.Environ;
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), Environ.getPosix(init.environ, "WAYLAND_DISPLAY")) catch {
        print("dazzle-text-editor: WAYLAND_DISPLAY needs XDG_RUNTIME_DIR\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, title) catch |err| {
        print("dazzle-text-editor: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("dazzle-text-editor");
    return win;
}

test {
    _ = file;
    _ = view;
    _ = syntax;
}
