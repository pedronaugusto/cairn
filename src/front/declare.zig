//! The facts a quest keeps, declared by its section as the story's own are:
//! each stage, true once it is reached, its own and those it inherits from
//! shared rules; its status and its current stage; what each `since` and
//! `before` in its conditions records; and for a repeat quest, how many
//! instances it has started. All are the game's, written by cairn, in the
//! scope the quest's `scope` names, and within the quest: `the_stranger.named`
//! to the rest of the story, `named` inside it. Those cairn keeps for itself
//! start with `@`, so no writer names them. A repeat quest is kept per a
//! thing of its own kind, so riverrun keys every fact it declares within it
//! by the instance.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const written = @import("written.zig");

const ast = riverrun.syntax.ast;
const Declared = riverrun.check.Declared;

/// What a `(quest)` section brings into the story: `Kind.declare`.
pub fn declare(a: std.mem.Allocator, s: *const ast.Section, files: []const ast.File) error{OutOfMemory}![]const Declared {
    var out: std.ArrayList(Declared) = .empty;
    const scope = written.scopeOf(s);
    var stages: std.ArrayList(ast.Name) = .empty;
    for (s.subsections) |*p| try stages.append(a, p.name);
    for (try written.inherited(a, files, s)) |i| try stages.append(a, .{ .text = i.part.name.text, .span = s.name.span });
    for (stages.items) |n| try out.append(a, .{ .scope = scope, .fact = .{ .name = n, .type = .boolean, .game = true }, .within = true });
    const at = s.name.span;
    try out.append(a, .{ .scope = scope, .fact = .{ .name = .{ .text = written.status, .span = at }, .type = .{ .one_of = try names(a, &written.statuses, at) }, .game = true }, .within = true });
    if (stages.items.len > 0) {
        try out.append(a, .{ .scope = scope, .fact = .{ .name = .{ .text = written.current, .span = at }, .type = .{ .one_of = stages.items }, .game = true }, .within = true });
    }
    for (try written.builtinCalls(a, s)) |w| {
        const record: ast.Type = if (std.mem.eql(u8, w.name, "since")) .int else .boolean;
        try out.append(a, .{ .scope = scope, .fact = .{ .name = .{ .text = try written.recordName(a, w), .span = at }, .type = record, .game = true }, .within = true });
    }
    // how many instances a repeat quest started is kept once, not per instance
    if (written.repeats(s)) {
        const name = try a.print("{s}.{s}", .{ s.name.text, written.count });
        try out.append(a, .{ .scope = scope, .fact = .{ .name = .{ .text = name, .span = at }, .type = .int, .game = true } });
    }
    return out.items;
}

/// The kind a repeat quest is kept per: its own name, so `bounty.done(lead)` reads one instance's.
pub fn per(s: *const ast.Section) ?ast.Name {
    return if (written.repeats(s)) s.name else null;
}

fn names(a: std.mem.Allocator, words: []const []const u8, at: riverrun.syntax.Span) error{OutOfMemory}![]const ast.Name {
    const out = try a.alloc(ast.Name, words.len);
    for (out, words) |*n, w| n.* = .{ .text = w, .span = at };
    return out;
}
