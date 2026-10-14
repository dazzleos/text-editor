//! The text editor's window, as widgets: the title bar (the file's name),
//! the text filling the window, and a line at the bottom saying where the
//! file is and whether it is saved. Without a file (started from the dock)
//! it shows a field pre-populated with a new file's name, a "New File"
//! button, and the list of recently opened files below it.

const std = @import("std");
const ui = @import("ui");

pub const min_size = [2]u32{ 480, 320 };

/// The size the window opens at: about 100 columns of text, and 30 lines.
pub const open_size = [2]u32{ 960, 720 };

/// Whether what is shown is saved.
pub const Saved = union(enum) {
    saved,
    /// Changed since, and saved in a moment.
    changed,
    /// It could not be, and why.
    failed: []const u8,
};

pub const Editor = struct {
    /// The file's path (none: no file was given).
    path: ?[]const u8,
    /// Its text; null if it could not be opened (and `message` says why).
    doc: ?*ui.TextDocument,
    message: []const u8 = "",
    /// Colours its code, if it is code (see syntax.zig).
    highlighter: ?ui.TextArea.Highlighter = null,
    saved: Saved = .saved,
    /// Start screen (when `path == null`): the pre-populated name for a new
    /// file, and the recently opened files below it.
    default_name: []const u8 = "Note 1.txt",
    recent: []const [:0]const u8 = &.{},
    on_name_changed: ?ui.ValueCallback([]const u8) = null,
    on_new_file: ?ui.Callback = null,
    on_open_recent: ?ui.ValueCallback([:0]const u8) = null,
    on_changed: ?ui.Callback = null,
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,

    pub const State = struct {
        dismissed: bool = false,
        last_err_buf: [128]u8 = undefined,
        last_err_len: u8 = 0,

        fn dismiss(st: *State) void {
            st.dismissed = true;
        }
    };

    pub fn build(self: *const Editor, cx: *ui.Context, state: *State) ui.Widget {
        const t = cx.theme();
        const name = if (self.path) |p| std.fs.path.basename(p) else "Text Editor";
        const body = if (self.doc) |d|
            cx.make(ui.TextArea{ .doc = d, .size = 18, .autofocus = true, .on_changed = self.on_changed, .highlighter = self.highlighter })
        else if (self.path == null)
            self.startScreen(cx)
        else
            cx.make(ui.Center{ .child = cx.make(ui.Padding{ .padding = .all(24), .child = cx.make(ui.Text{
                .text = self.message,
                .style = .{ .size = 20, .color = t.on_surface_variant },
                .text_align = .center,
            }) }) });
        const err_msg: []const u8 = switch (self.saved) {
            .failed => |why| cx.fmt("Not saved: {s}", .{why}),
            else => if (self.path == null and self.message.len > 0) self.message else "",
        };
        if (err_msg.len == 0) {
            state.dismissed = false;
            state.last_err_len = 0;
        } else if (!std.mem.eql(u8, state.last_err_buf[0..state.last_err_len], err_msg)) {
            const n: u8 = @intCast(@min(err_msg.len, state.last_err_buf.len));
            @memcpy(state.last_err_buf[0..n], err_msg[0..n]);
            state.last_err_len = n;
            state.dismissed = false;
        }
        const snackbar_msg = if (state.dismissed) "" else err_msg;
        const status: []const u8 = switch (self.saved) {
            .saved => "Saved",
            .changed => "Saving\u{2026}",
            .failed => "",
        };
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(ui.TitleBar{
                .title = name,
                .on_close = self.on_close,
                .on_maximize = self.on_maximize,
                .on_drag = self.on_drag,
                .maximized = self.maximized,
            }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Snackbar{
                .message = snackbar_msg,
                .on_dismiss = .of(state, State.dismiss),
                .child = cx.make(ui.Padding{ .padding = .all(12), .child = body }),
            }) }),
            if (self.doc != null) cx.make(ui.Padding{ .padding = .{ .left = 16, .right = 16, .bottom = 10 }, .child = cx.make(ui.Row{ .spacing = 16, .children = &.{
                cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = self.path orelse "", .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }) }),
                cx.make(ui.Text{ .text = status, .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false }),
            } }) }) else cx.make(ui.Empty{}),
        } });
    }

    fn startScreen(self: *const Editor, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const a = cx.ui.arena();
        const list_content = if (self.recent.len == 0)
            cx.make(ui.Center{ .child = cx.make(ui.Padding{ .padding = .all(16), .child = cx.make(ui.Text{
                .text = "No recently opened files",
                .style = .{ .size = 16, .color = t.on_surface_variant },
                .text_align = .center,
            }) }) })
        else blk: {
            var rows: std.ArrayList(ui.Widget) = .empty;
            for (self.recent) |r| {
                rows.append(a, cx.make(ui.ListItem{
                    .leading_icon = .description,
                    .headline = std.fs.path.basename(r),
                    .supporting_text = std.fs.path.dirname(r) orelse "",
                    .on_press = recentCallback(cx, self.on_open_recent, r),
                })) catch break;
            }
            break :blk cx.make(ui.ScrollView{ .child = cx.make(ui.Column{
                .cross_axis_alignment = .stretch,
                .spacing = 4,
                .children = rows.items,
            }) });
        };

        return cx.make(ui.Center{ .height_factor = 1, .child = cx.make(ui.ConstrainedBox{
            .constraints = .{ .max_w = 560 },
            .child = cx.make(ui.Padding{ .padding = .symmetric(12, 8), .child = cx.make(ui.Column{
                .cross_axis_alignment = .stretch,
                .spacing = 12,
                .children = &.{
                    cx.make(ui.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
                        cx.make(ui.Expanded{ .child = cx.make(ui.TextField{
                            .initial = self.default_name,
                            .placeholder = "File name",
                            .width = std.math.inf(f32),
                            .max_len = ui.TextField.capacity,
                            .autofocus = true,
                            .on_changed = self.on_name_changed,
                            .on_submit = self.on_new_file,
                        }) }),
                        cx.make(ui.FilledButton{
                            .label = "New File",
                            .icon = .note_add,
                            .on_press = self.on_new_file,
                        }),
                    } }),
                    cx.make(ui.Padding{ .padding = .{ .top = 4 }, .child = cx.make(ui.Text{
                        .text = "Recent files",
                        .style = .{ .size = 16, .color = t.on_surface_variant },
                        .wrap = false,
                    }) }),
                    cx.make(ui.Divider{}),
                    cx.make(ui.Expanded{ .child = list_content }),
                },
            }) }),
        }) });
    }
};

const RecentPress = struct {
    cb: ui.ValueCallback([:0]const u8),
    path: [:0]const u8,

    fn press(r: *const RecentPress) void {
        r.cb.call(r.path);
    }
};

fn recentCallback(cx: *ui.Context, cb: ?ui.ValueCallback([:0]const u8), path: [:0]const u8) ?ui.Callback {
    const f = cb orelse return null;
    const p = cx.ui.arena().create(RecentPress) catch return null;
    p.* = .{ .cb = f, .path = path };
    return .of(p, RecentPress.press);
}

// --- Tests ---------------------------------------------------------------------

const testing = std.testing;
const font = @import("font");

fn overflows(node: *ui.Node) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

fn findType(n: *ui.Node, comptime T: type) ?*ui.Node {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (findType(ch, T)) |f| return f;
    return null;
}

fn findText(n: *ui.Node, text: []const u8) ?*ui.Node {
    if (n.widget.as(ui.Text)) |tx| if (std.mem.eql(u8, tx.text, text)) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

fn up(n: *ui.Node, comptime T: type) ?*ui.Node {
    var at: ?*ui.Node = n;
    while (at) |a| : (at = a.parent) if (a.widget.is(T)) return a;
    return null;
}

fn click(u: *ui.Ui, n: *ui.Node) void {
    const at = n.position();
    const p: ui.Point = .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, ui.btn_left, true);
    u.pointerButton(p, ui.btn_left, false);
}

test "the text fills the window; whether it is saved, and without a file the start screen" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var doc = try ui.TextDocument.init(testing.allocator, "Shopping\n\nmilk\nbread\n");
    defer doc.deinit();
    var e: Editor = .{ .path = "/data/user/notes.txt", .doc = &doc };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, e);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "notes.txt") != null);
    try testing.expect(findText(u.root.?, "Saved") != null);
    e.saved = .changed;
    u.frame(1280, 720, 1, e);
    try testing.expect(findText(u.root.?, "Saving\u{2026}") != null);
    e.saved = .{ .failed = "there is no space left" };
    u.frame(1280, 720, 2, e);
    try testing.expect(findText(u.root.?, "Not saved: there is no space left") != null);
    // The text has the keyboard.
    try testing.expect(u.focused != null and u.focused.?.widget.is(ui.TextArea));
    // Code is coloured, as the text changes.
    var code = try ui.TextDocument.init(testing.allocator, "const x = @import(\"std\"); // here\n");
    defer code.deinit();
    u.frame(1280, 720, 3, Editor{ .path = "/data/user/a.zig", .doc = &code, .highlighter = @import("syntax.zig").zig });
    code.moveTo(code.text().len, false);
    code.insert("fn f() void {}\n");
    u.frame(1280, 720, 4, Editor{ .path = "/data/user/a.zig", .doc = &code, .highlighter = @import("syntax.zig").zig });
    const area = findType(u.root.?, ui.TextArea).?;
    const st = area.state(ui.TextArea.State);
    try testing.expectEqual(code.text().len, st.colours.items.len);
    try testing.expectEqual(ui.Highlight.keyword, st.colours.items[0]);
    try testing.expectEqual(ui.Highlight.function, st.colours.items[code.text().len - 12]);

    // Without a file: pre-populated file name, New File button, and recent files.
    const Sink = struct {
        made: bool = false,
        opened: ?[:0]const u8 = null,
        fn make(s: *@This()) void {
            s.made = true;
        }
        fn open(s: *@This(), p: [:0]const u8) void {
            s.opened = p;
        }
    };
    var sink: Sink = .{};
    const recent = [_][:0]const u8{ "/data/user/Note 1.txt", "/data/user/todo.txt" };
    const start: Editor = .{
        .path = null,
        .doc = null,
        .default_name = "Note 2.txt",
        .recent = &recent,
        .on_new_file = .of(&sink, Sink.make),
        .on_open_recent = .of(&sink, Sink.open),
    };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 5, start);
        try testing.expect(!overflows(u.root.?));
    }
    const field = findType(u.root.?, ui.TextField).?;
    try testing.expectEqualStrings("Note 2.txt", field.state(ui.TextField.State).text());
    try testing.expect(findText(u.root.?, "New File") != null);
    try testing.expect(findText(u.root.?, "Recent files") != null);
    try testing.expect(findText(u.root.?, "Note 1.txt") != null);
    try testing.expect(findText(u.root.?, "todo.txt") != null);

    click(u, up(findText(u.root.?, "New File").?, ui.FilledButton).?);
    try testing.expect(sink.made);
    click(u, up(findText(u.root.?, "todo.txt").?, ui.ListItem).?);
    try testing.expectEqualStrings("/data/user/todo.txt", sink.opened.?);
}
