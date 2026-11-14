//! A quest as its section is written: its stages, what kind each is, what
//! it comes after, its roles, the shared rules it inherits, and the calls of
//! cairn's builtins in its conditions, read from the syntax tree alone.
//! What a quest declares, what cairn's judges hold a tag to and what the
//! reader makes of a checked story all start here, so the three agree.
//!
//!     == the_stranger (quest)
//!       [title "Who was he?"] [scope player]
//!     facts (player):
//!       stranger: ref of person   (role)
//!     = noticed   when { met }
//!       [stage]
//!     = gone      when { hour >= 6 }
//!       [fails]
//!
//!     == everyone (quest rules)
//!     facts:
//!       giver: ref of person   (role)
//!     = abandoned   when { not alive(giver) }
//!       [fails]

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const cairn = @import("cairn");

const ast = riverrun.syntax.ast;
const sym = riverrun.check.symbols;
const Kind = cairn.block.Kind;

/// The kind of section a quest is.
pub const quest = "quest";
/// The kind of section rules many quests share are.
pub const rules = "quest rules";
/// The kind of thing an activation key is, as the host's manifest lists them.
pub const activation = "activation";

pub fn isQuest(s: sym.Section) bool {
    return s.kind == .other and std.mem.eql(u8, s.kind.other, quest);
}

pub fn isRules(s: sym.Section) bool {
    return s.kind == .other and std.mem.eql(u8, s.kind.other, rules);
}

pub fn kindIs(s: *const ast.Section, name: []const u8) bool {
    return s.kind == .other and std.mem.eql(u8, s.kind.other.text, name);
}

pub fn tagOf(tags: []const ast.Tag, key: []const u8) ?*const ast.Tag {
    for (tags) |*t| if (std.mem.eql(u8, t.key.text, key)) return t;
    return null;
}

pub fn has(tags: []const ast.Tag, key: []const u8) bool {
    return tagOf(tags, key) != null;
}

/// A tag's one value; the checker holds a key to its count, so a missing one reads as empty.
pub fn only(t: *const ast.Tag) []const u8 {
    return if (t.values.len > 0) t.values[0] else "";
}

/// The kinds a part may be, by the mark it carries.
pub const kinds = [_]Kind{ .stage, .objective, .outcome, .fails };

/// What kind of stage a part is, by its mark; null where it carries none, or more than one.
pub fn kindOf(p: *const ast.Subsection) ?Kind {
    var found: ?Kind = null;
    for (kinds) |k| if (has(p.tags, @tagName(k))) {
        if (found != null) return null;
        found = k;
    };
    return found;
}

/// The scope a quest keeps its stages in, from its `scope`; null for the story's default.
pub fn scopeOf(s: *const ast.Section) ?[]const u8 {
    const t = tagOf(s.tags, "scope") orelse return null;
    return if (t.values.len == 1) t.values[0] else null;
}

/// A quest tagged `repeat` runs as many instances, each kept per a thing of the quest's own kind.
pub fn repeats(s: *const ast.Section) bool {
    return has(s.tags, "repeat");
}

/// A quest starts itself when a stage with no `after` is reached, unless only the host starts it.
pub fn startsItself(s: *const ast.Section) bool {
    if (repeats(s)) return false;
    const t = tagOf(s.tags, "start") orelse return true;
    return !std.mem.eql(u8, only(t), "host");
}

/// The section's roles, its own facts marked `(role)`, in the order written.
pub fn roles(a: std.mem.Allocator, s: *const ast.Section) error{OutOfMemory}![]const *const ast.Fact {
    var out: std.ArrayList(*const ast.Fact) = .empty;
    for (s.facts) |block| for (block.entries) |*e| if (e.role) try out.append(a, e);
    return out.items;
}

/// Whether the section names a role `name` among its own facts.
pub fn hasRole(s: *const ast.Section, name: []const u8) bool {
    for (s.facts) |block| for (block.entries) |e| if (e.role and std.mem.eql(u8, e.name.text, name)) return true;
    return false;
}

/// The part of `s` called `name`.
pub fn part(s: *const ast.Section, name: []const u8) ?*const ast.Subsection {
    for (s.subsections) |*p| if (std.mem.eql(u8, p.name.text, name)) return p;
    return null;
}

// ---------------------------------------------------------------- what a quest inherits

/// A stage a quest inherits: a part of a `(quest rules)` section.
pub const Inherited = struct { rules: *const ast.Section, part: *const ast.Subsection };

/// The stages `q` inherits from the story's shared rules: each part of a `(quest rules)` section in its module or
/// the root whose condition reads roles `q` has every one of, or of one `q` follows (`[follows name]`), and
/// that `q` does not say otherwise of with a stage of its own name.
pub fn inherited(a: std.mem.Allocator, files: []const ast.File, q: *const ast.Section) error{OutOfMemory}![]const Inherited {
    var out: std.ArrayList(Inherited) = .empty;
    const module = moduleOf(files, q);
    for (files) |f| {
        const theirs = if (f.module) |m| m.text else "";
        if (theirs.len != 0 and !std.mem.eql(u8, theirs, module)) continue;
        for (f.sections) |*r| {
            if (!kindIs(r, rules)) continue;
            const follows = followsRules(q, r.name.text);
            for (r.subsections) |*p| {
                if (part(q, p.name.text) != null) continue;
                const read = try rolesRead(a, r, p);
                if (!follows and read.len == 0) continue;
                const fits = for (read) |n| {
                    if (!hasRole(q, n)) break false;
                } else true;
                if (fits or follows) try out.append(a, .{ .rules = r, .part = p });
            }
        }
    }
    return out.items;
}

fn followsRules(q: *const ast.Section, name: []const u8) bool {
    const t = tagOf(q.tags, "follows") orelse return false;
    for (t.values) |v| if (std.mem.eql(u8, v, name)) return true;
    return false;
}

/// The module the file holding `s` is in; empty for the root.
pub fn moduleOf(files: []const ast.File, s: *const ast.Section) []const u8 {
    for (files) |f| for (f.sections) |*x| if (x == s) return if (f.module) |m| m.text else "";
    return "";
}

/// The roles of `r` that part `p`'s condition names.
pub fn rolesRead(a: std.mem.Allocator, r: *const ast.Section, p: *const ast.Subsection) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const w = if (p.when) |*w| w else return out.items;
    try namesIn(a, w, r, &out);
    return out.items;
}

fn namesIn(a: std.mem.Allocator, e: *const ast.Expr, r: *const ast.Section, out: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
    switch (e.kind) {
        .name => |n| if (hasRole(r, n)) {
            for (out.items) |had| if (std.mem.eql(u8, had, n)) return;
            try out.append(a, n);
        },
        .call => |c| for (c.args) |*arg| try namesIn(a, arg, r, out),
        .not => |inner| try namesIn(a, inner, r, out),
        .binary => |b| {
            try namesIn(a, b.lhs, r, out);
            try namesIn(a, b.rhs, r, out);
        },
        .int, .string, .boolean => {},
    }
}

// ---------------------------------------------------------------- builtin calls

/// A call of one of cairn's builtins as written: `since(stage, fact)` or `before(a, b)`, its arguments' names.
pub const Written = struct { name: []const u8, a: []const u8, b: []const u8 };

/// The calls of `since` and `before` in `s`'s parts, their conditions and their journal's words, each once.
pub fn builtinCalls(a: std.mem.Allocator, s: *const ast.Section) error{OutOfMemory}![]const Written {
    var out: std.ArrayList(Written) = .empty;
    for (s.subsections) |*p| {
        if (p.when) |*w| try callsIn(a, w, &out);
        for (p.body) |*st| try callsInStmt(a, st, &out);
    }
    return out.items;
}

fn callsInStmt(a: std.mem.Allocator, st: *const ast.Stmt, out: *std.ArrayList(Written)) error{OutOfMemory}!void {
    switch (st.kind) {
        .line => |l| {
            try callsInText(a, l.text, out);
            for (l.effects) |*e| try callsInStmt(a, e, out);
        },
        .effect => |e| switch (e) {
            .set => |x| try callsIn(a, &x.value, out),
            .call => |c| for (c.args) |*arg| try callsIn(a, arg, out),
            // an int's amount may be a sum that reads a builtin, `[n += since(met, day) + 1]`
            .add, .remove => |x| try callsIn(a, &x.amount, out),
        },
        else => {},
    }
}

fn callsInText(a: std.mem.Allocator, t: ast.Text, out: *std.ArrayList(Written)) error{OutOfMemory}!void {
    for (t) |*piece| switch (piece.kind) {
        .literal => {},
        .value => |*e| try callsIn(a, e, out),
        .choose => |*ch| {
            try callsIn(a, &ch.cond, out);
            try callsInText(a, ch.then, out);
            try callsInText(a, ch.otherwise, out);
        },
        .alternatives => |alt| for (alt.options) |o| try callsInText(a, o, out),
        .select => |*sel| {
            try callsIn(a, &sel.operand, out);
            for (sel.branches) |b| try callsInText(a, b.text, out);
        },
    };
}

fn callsIn(a: std.mem.Allocator, e: *const ast.Expr, out: *std.ArrayList(Written)) error{OutOfMemory}!void {
    switch (e.kind) {
        .call => |c| {
            const ours = std.mem.eql(u8, c.name.text, "since") or std.mem.eql(u8, c.name.text, "before");
            if (ours and c.args.len == 2 and c.args[0].kind == .name and c.args[1].kind == .name) {
                const w: Written = .{ .name = c.name.text, .a = c.args[0].kind.name, .b = c.args[1].kind.name };
                for (out.items) |had| if (std.mem.eql(u8, had.name, w.name) and std.mem.eql(u8, had.a, w.a) and std.mem.eql(u8, had.b, w.b)) return;
                try out.append(a, w);
            }
            for (c.args) |*arg| try callsIn(a, arg, out);
        },
        .not => |inner| try callsIn(a, inner, out),
        .binary => |b| {
            try callsIn(a, b.lhs, out);
            try callsIn(a, b.rhs, out);
        },
        .name, .int, .string, .boolean => {},
    }
}

/// The name of the fact that keeps what a builtin call records: `@since.stage.fact` or `@before.a.b`, within its
/// quest, which no writer can name.
pub fn recordName(a: std.mem.Allocator, w: Written) error{OutOfMemory}![]const u8 {
    return a.print("@{s}.{s}.{s}", .{ w.name, w.a, w.b });
}

/// The names of what cairn keeps for every quest, within it, which no writer can name.
pub const status = "@status";
pub const current = "@current";
/// For a repeat quest, how many instances it has started: `quest.@count`, kept once, not per instance.
pub const count = "@count";
/// The values of a quest's status: none until it starts.
pub const statuses = [_][]const u8{ "active", "done", "failed" };

test "a part's kind is its one mark" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: riverrun.syntax.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const f = try riverrun.syntax.parse(arena.allocator(), std.testing.allocator, &diags, 0, "a.river",
        \\== q (quest)
        \\  [repeat]
        \\= a   when { since(a, day) > 3 and before(a, b) }
        \\  [stage]
        \\= b   when { since(a, day) > 4 }
        \\  [outcome] [stage]
        \\= c
    );
    const q = &f.sections[0];
    try std.testing.expectEqual(@as(?Kind, .stage), kindOf(&q.subsections[0]));
    try std.testing.expectEqual(@as(?Kind, null), kindOf(&q.subsections[1]));
    try std.testing.expectEqual(@as(?Kind, null), kindOf(&q.subsections[2]));
    try std.testing.expect(repeats(q) and !startsItself(q));
    const calls = try builtinCalls(arena.allocator(), q);
    try std.testing.expectEqual(@as(usize, 2), calls.len);
    try std.testing.expectEqualStrings("@before.a.b", try recordName(arena.allocator(), calls[1]));
}
