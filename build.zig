//! Text Editor, an app for writing and editing plain text files, for Dazzle: built with Dazzle's modules and
//! tools (see Dazzle's build.zig, `addApp`).
//!
//!     zig build                 the program, and its archive and catalogue (zig-out/apps)
//!     zig build test            its tests, on this computer
//!
//! With a Dazzle (or kete) checkout of your own beside it:
//! `zig build --fork=../dazzle`.

const std = @import("std");
const dazzle = @import("dazzle");

pub fn build(b: *std.Build) void {
    _ = dazzle.addApp(b, .{
        .name = "dazzle-text-editor",
        .icon = .edit_note,
        .title = "Text Editor",
        .description = "Edit text files",
        .about = "Write and edit plain text files: notes, lists, code and configuration. It opens text files from Files, and keeps what you write as you go.",
        .handles = &.{"text/plain"},
    });
}
