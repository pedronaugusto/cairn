//! A checked story's quests: each `(quest)` section's stages, its own and
//! those it inherits from shared rules, what kind each is, what it comes
//! after, the roles it reads and the keys it activates, and the calls of
//! cairn's builtins it makes. What only a quest as a whole shows (a part of
//! no kind, an ending that could be live, an `after` that goes round, a
//! quest's facts kept apart from its stages) is a problem with the place it
//! is written; what a tag gets wrong alone its judge has said. Ids are the
//! checker's until the compile pass maps them to the compiled story's.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const cairn = @import("cairn");
const written = @import("written.zig");

const check = riverrun.check;
const sym = check.symbols;
const ast = riverrun.syntax.ast;
const Span = riverrun.syntax.Span;
const Kind = cairn.block.Kind;
const block = cairn.block;

pub const Problem = struct {
    span: Span,
    message: []const u8,
    severity: riverrun.syntax.source.Severity = .err,
};

/// A role a stage's terms read: the fact they read it as, and which of the quest's roles it is.
pub const RoleRead = struct { fact: sym.FactId, role: u8 };

pub const Stage = struct {
    name: []const u8,
    /// The section its part is written in: the quest's own, or the shared rules' it is inherited from.
    owner: sym.SectionId,
    /// Its part's place there.
    index: u16,
    node: *const ast.Subsection,
    /// The fact true once it is reached, the quest's.
    fact: sym.FactId,
    kind: Kind,
    live: bool,
    optional: bool,
    after: []const u8,
    active: []const []const u8,
    keeps: []const []const u8,
    roles: []const RoleRead,
};

/// A call of `since` or `before` a quest makes, and the fact that keeps what it records.
pub const Call = struct {
    what: enum { since, before },
    a: u8,
    /// `before`'s second stage.
    b: u8 = 0,
    /// `since`'s int fact.
    fact: ?sym.FactId = null,
    record: sym.FactId,
};

pub const Quest = struct {
    section: sym.SectionId,
    repeat: bool,
    starts_itself: bool,
    status: sym.FactId,
    current: ?sym.FactId,
    count: ?sym.FactId,
    roles: []const sym.FactId,
    stages: []const Stage,
    calls: []const Call,
};

pub const Read = struct {
    quests: []const Quest,
    problems: []const Problem,
};

/// Reads `checked`'s quests; lists are on `arena`.
pub fn read(arena: std.mem.Allocator, checked: *const check.Checked) error{OutOfMemory}!Read {
    var r: Reader = .{ .a = arena, .checked = checked };
    // each section's roles, in the order its facts are declared
    for (checked.facts, 0..) |f, i| if (f.role) if (f.by) |by| {
        const gop = try r.roles.getOrPut(arena, by);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, sym.idOf(sym.FactId, i));
    };
    for (checked.sections, 0..) |s, i| {
        const id = sym.idOf(sym.SectionId, i);
        if (written.isQuest(s)) try r.quests.append(arena, try r.quest(id));
        if (written.isRules(s)) for (s.parts, 0..) |_, k| {
            _ = try r.shape(id, @intCast(k)); // safe: a section's parts number at most a u16
        };
    }
    return .{ .quests = r.quests.items, .problems = r.problems.items };
}

const Reader = struct {
    a: std.mem.Allocator,
    checked: *const check.Checked,
    quests: std.ArrayList(Quest) = .empty,
    problems: std.ArrayList(Problem) = .empty,
    roles: std.AutoHashMapUnmanaged(sym.SectionId, std.ArrayList(sym.FactId)) = .empty,

    fn problem(r: *Reader, span: Span, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        try r.problems.append(r.a, .{ .span = span, .message = try r.a.print(fmt, args) });
    }

    fn warning(r: *Reader, span: Span, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        try r.problems.append(r.a, .{ .span = span, .message = try r.a.print(fmt, args), .severity = .warning });
    }

    // A fact the quest declares within it, by its name there.
    fn own(r: *const Reader, q: sym.Section, name: []const u8) ?sym.FactId {
        var buf: [512]u8 = undefined;
        const full = std.mem.print(&buf, "{s}.{s}", .{ q.name, name }) catch return null;
        const named = r.checked.value_names.map.get(.{ .module = q.module, .name = full }) orelse return null;
        return if (named == .fact) named.fact else null;
    }

    fn quest(r: *Reader, id: sym.SectionId) error{OutOfMemory}!Quest {
        const s = r.checked.sections[id.raw()];
        const roles = try r.rolesOf(id);
        try r.together(s);
        var stages: std.ArrayList(Stage) = .empty;
        for (s.parts, 0..) |_, k| {
            const k16: u16 = @intCast(k); // safe: a section's parts number at most a u16
            var st = try r.shape(id, k16) orelse continue;
            st.fact = r.own(s, st.name) orelse continue;
            st.roles = try r.identity(roles);
            try stages.append(r.a, st);
        }
        for (try written.inherited(r.a, r.checked.files, s.node)) |h| if (try r.inherit(id, roles, h)) |st| try stages.append(r.a, st);
        if (stages.items.len > block.max_stages) try r.problem(s.node.name.span, "`{s}` has {d} stages, more than {d}", .{ s.name, stages.items.len, block.max_stages });
        if (stages.items.len > block.max_stages) stages.shrinkRetainingCapacity(block.max_stages);
        try r.afters(s, stages.items);
        const ends = for (stages.items) |st| {
            if (st.kind.ends()) break true;
        } else false;
        if (!ends) try r.warning(s.node.name.span, "`{s}` has no outcome and no failure, so it never ends", .{s.name});
        return .{
            .section = id,
            .repeat = written.repeats(s.node),
            .starts_itself = written.startsItself(s.node),
            .status = r.own(s, written.status).?, // declared for every quest
            .current = r.own(s, written.current),
            .count = r.count(s),
            .roles = roles,
            .stages = stages.items,
            .calls = try r.calls(s, stages.items),
        };
    }

    fn count(r: *const Reader, s: sym.Section) ?sym.FactId {
        if (!written.repeats(s.node)) return null;
        var buf: [512]u8 = undefined;
        const full = std.mem.print(&buf, "{s}.{s}", .{ s.name, written.count }) catch return null;
        const named = r.checked.value_names.map.get(.{ .module = s.module, .name = full }) orelse return null;
        return if (named == .fact) named.fact else null;
    }

    // The quest's roles in the order written, and its own facts kept with its stages, in one scope.
    fn rolesOf(r: *Reader, id: sym.SectionId) error{OutOfMemory}![]const sym.FactId {
        const s = r.checked.sections[id.raw()];
        const all = if (r.roles.get(id)) |l| l.items else return &.{};
        if (all.len <= block.max_roles) return all;
        try r.problem(r.checked.facts[all[block.max_roles].raw()].span, "`{s}` has more than {d} roles", .{ s.name, block.max_roles });
        return all[0..block.max_roles];
    }

    // A quest's own facts are saved with its stages, so they are kept in the scope the quest's `scope` names.
    fn together(r: *Reader, s: sym.Section) error{OutOfMemory}!void {
        const scope = written.scopeOf(s.node);
        for (s.node.facts) |b| {
            const theirs: ?[]const u8 = if (b.scope) |n| n.text else null;
            const same = if (scope) |want| (theirs != null and std.mem.eql(u8, want, theirs.?)) else theirs == null;
            if (same or b.entries.len == 0) continue;
            try r.problem(b.entries[0].name.span, "`{s}`'s facts are saved with its stages: declare them `facts{s}{s}{s}:`, the scope its `scope` names", .{ s.name, if (scope != null) " (" else "", scope orelse "", if (scope != null) ")" else "" });
        }
    }

    fn identity(r: *Reader, roles: []const sym.FactId) error{OutOfMemory}![]const RoleRead {
        const out = try r.a.alloc(RoleRead, roles.len);
        for (out, roles, 0..) |*o, f, i| o.* = .{ .fact = f, .role = @intCast(i) }; // safe: at most max_roles
        return out;
    }

    // A part of a quest or of shared rules as a stage: its kind, its marks, its condition and its body.
    fn shape(r: *Reader, owner: sym.SectionId, index: u16) error{OutOfMemory}!?Stage {
        const s = r.checked.sections[owner.raw()];
        const p = s.parts[index].node;
        const kind = written.kindOf(p) orelse {
            try r.problem(p.name.span, "`{s}` is a stage, an objective, an outcome or a failure: mark it with one of `stage`, `objective`, `outcome` or `fails`", .{p.name.text});
            return null;
        };
        const live = written.has(p.tags, "live");
        const optional = written.has(p.tags, "optional");
        if (live and kind.ends()) try r.problem(p.name.span, "`{s}` ends the quest, which stays ended: an ending is never `live`", .{p.name.text});
        if (optional and kind != .objective) try r.problem(p.name.span, "only an objective is `optional`: `{s}` is a {s}", .{ p.name.text, @tagName(kind) });
        if (p.when == null) try r.problem(p.name.span, "`{s}` is reached when its condition holds: `= {s} when {{ … }}`", .{ p.name.text, p.name.text });
        for (p.body) |st| if (!journal(st)) {
            try r.problem(st.span, "under a stage go its journal's lines and what reaching it does, `[…]`: nothing else", .{});
            break;
        };
        return .{
            .name = p.name.text,
            .owner = owner,
            .index = index,
            .node = p,
            .fact = .fromRaw(0),
            .kind = kind,
            .live = live,
            .optional = optional,
            .after = &.{},
            .active = if (written.tagOf(p.tags, "active")) |t| t.values else &.{},
            .keeps = if (written.tagOf(p.tags, "keeps")) |t| t.values else &.{},
            .roles = &.{},
        };
    }

    fn journal(st: ast.Stmt) bool {
        return switch (st.kind) {
            .line => |l| for (l.effects) |e| {
                if (e.kind != .effect) break false;
            } else true,
            .effect => true,
            else => false,
        };
    }

    // A stage `q` inherits from shared rules, read as the quest's, its terms reading the rules' roles as `q`'s.
    fn inherit(r: *Reader, q: sym.SectionId, roles: []const sym.FactId, h: written.Inherited) error{OutOfMemory}!?Stage {
        const rules_id = r.sectionOf(h.rules) orelse return null;
        const rules = r.checked.sections[rules_id.raw()];
        const index: u16 = for (rules.parts, 0..) |p, k| {
            if (p.node == h.part) break @intCast(k); // safe: a section's parts number at most a u16
        } else return null;
        // what is wrong with the part itself is said once, where the rules are written
        const said = r.problems.items.len;
        var st = (try r.shape(rules_id, index)) orelse return null;
        r.problems.shrinkRetainingCapacity(said);
        const quest_s = r.checked.sections[q.raw()];
        st.fact = r.own(quest_s, st.name) orelse return null;
        var reads: std.ArrayList(RoleRead) = .empty;
        for (try written.rolesRead(r.a, h.rules, h.part)) |name| {
            const theirs = r.own(rules, name) orelse continue;
            const mine = r.own(quest_s, name) orelse continue;
            const i = std.mem.findScalar(sym.FactId, roles, mine) orelse continue;
            if (!r.checked.facts[theirs.raw()].type.eql(r.checked.facts[mine.raw()].type)) {
                try r.problem(quest_s.node.name.span, "`{s}` inherits `{s}` from `{s}`, whose `{s}` is not the same kind of thing as its own", .{ quest_s.name, st.name, rules.name, name });
                continue;
            }
            try reads.append(r.a, .{ .fact = theirs, .role = @intCast(i) }); // safe: at most max_roles
        }
        st.roles = reads.items;
        return st;
    }

    fn sectionOf(r: *const Reader, node: *const ast.Section) ?sym.SectionId {
        for (r.checked.sections, 0..) |s, i| if (s.node == node) return sym.idOf(sym.SectionId, i);
        return null;
    }

    // Each stage's `after`, by the stages' places in the quest, and no `after` that comes round to itself.
    fn afters(r: *Reader, s: sym.Section, stages: []Stage) error{OutOfMemory}!void {
        for (stages) |*st| {
            const t = written.tagOf(st.node.tags, "after") orelse continue;
            var list: std.ArrayList(u8) = .empty;
            for (t.values) |v| for (stages, 0..) |other, k| if (std.mem.eql(u8, other.name, v)) {
                try list.append(r.a, @intCast(k)); // safe: at most max_stages
            };
            st.after = list.items;
        }
        const state = try r.a.alloc(u8, stages.len);
        @memset(state, 0);
        for (0..stages.len) |k| if (try r.round(stages, state, k)) |at| {
            try r.problem(stages[at].node.name.span, "`{s}`'s `after` comes round to it again: what comes after what in `{s}` goes one way", .{ stages[at].name, s.name });
            return;
        };
    }

    // Depth first over `after`: the stage found on a cycle, if one is.
    fn round(r: *Reader, stages: []const Stage, state: []u8, k: usize) error{OutOfMemory}!?usize {
        if (state[k] == 2) return null;
        if (state[k] == 1) return k;
        state[k] = 1;
        for (stages[k].after) |b| if (try r.round(stages, state, b)) |at| return at;
        state[k] = 2;
        return null;
    }

    // The calls of `since` and `before` the quest's own stages make, each with the fact that keeps what it records.
    fn calls(r: *Reader, s: sym.Section, stages: []const Stage) error{OutOfMemory}![]const Call {
        var out: std.ArrayList(Call) = .empty;
        for (try written.builtinCalls(r.a, s.node)) |w| {
            const record = r.own(s, try written.recordName(r.a, w)) orelse continue;
            const a = stageIndex(stages, w.a) orelse continue;
            if (std.mem.eql(u8, w.name, "since")) {
                const f = r.factNamed(s, w.b) orelse continue;
                try out.append(r.a, .{ .what = .since, .a = a, .fact = f, .record = record });
            } else {
                const b = stageIndex(stages, w.b) orelse continue;
                try out.append(r.a, .{ .what = .before, .a = a, .b = b, .record = record });
            }
        }
        return out.items;
    }

    // A fact as a condition of quest `s` names it: its own first, then its module's and the root's, or another
    // module's as `module.name`.
    fn factNamed(r: *const Reader, s: sym.Section, name: []const u8) ?sym.FactId {
        if (r.own(s, name)) |f| return f;
        const named = blk: {
            if (std.mem.findScalar(u8, name, '.')) |dot| for (r.checked.modules, 0..) |m, i| if (std.mem.eql(u8, m, name[0..dot])) {
                break :blk r.checked.value_names.map.get(.{ .module = sym.idOf(sym.ModuleId, i), .name = name[dot + 1 ..] });
            };
            break :blk r.checked.value_names.find(s.module, name);
        } orelse return null;
        return if (named == .fact) named.fact else null;
    }
};

pub fn stageIndex(stages: []const Stage, name: []const u8) ?u8 {
    for (stages, 0..) |st, k| if (std.mem.eql(u8, st.name, name)) return @intCast(k); // safe: at most max_stages
    return null;
}
