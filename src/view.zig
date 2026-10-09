//! The text editor's window, as widgets: the title bar (the file's name),
//! the text filling the window, and a line at the bottom saying where the
//! file is and whether it is saved. Without a file (started from the dock)
//! it says how to open one.

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
    on_changed: ?ui.Callback = null,
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,

    pub fn build(self: *const Editor, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const name = if (self.path) |p| std.fs.path.basename(p) else "Text Editor";
        const body = if (self.doc) |d|
            cx.make(ui.TextArea{ .doc = d, .size = 18, .autofocus = true, .on_changed = self.on_changed, .highlighter = self.highlighter })
        else
            cx.make(ui.Center{ .child = cx.make(ui.Padding{ .padding = .all(24), .child = cx.make(ui.Text{
                .text = if (self.path == null) "Open a text file from Files to edit it: pick it, then Edit. New text file there makes one." else self.message,
                .style = .{ .size = 20, .color = t.on_surface_variant },
                .text_align = .center,
            }) }) });
        const status: []const u8 = switch (self.saved) {
            .saved => "Saved",
            .changed => "Saving\u{2026}",
            .failed => |why| cx.fmt("Not saved: {s}", .{why}),
        };
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(ui.TitleBar{
                .title = name,
                .on_close = self.on_close,
                .on_maximize = self.on_maximize,
                .on_drag = self.on_drag,
                .maximized = self.maximized,
            }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Padding{ .padding = .all(12), .child = body }) }),
            if (self.doc != null) cx.make(ui.Padding{ .padding = .{ .left = 16, .right = 16, .bottom = 10 }, .child = cx.make(ui.Row{ .spacing = 16, .children = &.{
                cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = self.path orelse "", .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }) }),
                cx.make(ui.Text{ .text = status, .style = .{ .size = 15, .color = if (self.saved == .failed) t.@"error" else t.on_surface_variant }, .wrap = false }),
            } }) }) else cx.make(ui.Empty{}),
        } });
    }
};

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

test "the text fills the window; whether it is saved, and without a file how to open one" {
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
    // No file.
    u.frame(1280, 720, 5, Editor{ .path = null, .doc = null });
    try testing.expect(findText(u.root.?, "Open a text file from Files to edit it: pick it, then Edit. New text file there makes one.") != null);
}
