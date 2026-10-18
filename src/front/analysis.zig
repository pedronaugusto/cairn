//! What only a quest's conditions as a whole show, decided where it can be.
//! A condition is a formula over atoms: a bool fact, a `one of` holding a
//! value, a set holding an item, the quest's own stages. Each atom moves only
//! as the story's effects can move it (the game's facts and another quest's
//! stages any way they may), and anything else a condition reads (a number,
//! a query, a builtin) is an atom free to be either, so what depends on it is
//! never decided but left unknown, and never reported. Over the atoms:
//!
//! - two endings that can hold together, which would end the quest twice;
//! - a quest that can get stuck: a state the story can reach from which no
//!   outcome or failure can ever be, reported with the way there;
//! - a stage nothing can make reachable;
//! - stages whose conditions read each other round through a live stage,
//!   which could keep each other changing for ever.
//!
//! The model counts the story's effects as able to happen at any time, in any
//! order; a host's own writes are the game's facts'. Past its bounds (atoms,
//! states) a quest is left unknown.

const std = @import("std");
const riverrun = @import("riverrun-compiler");

const check = riverrun.check;
const sym = check.symbols;
const ast = riverrun.syntax.ast;
const Span = riverrun.syntax.Span;

/// The most atoms a quest's conditions are decided over.
pub const max_atoms = 64;
/// The most atoms two endings are tried together over.
pub const max_together = 20;
/// The most states a quest's model explores before it is left unknown.
pub const max_states = 1 << 15;

pub const Atom = union(enum) {
    flag: sym.FactId,
    is: struct { fact: sym.FactId, value: u16 },
    has: struct { fact: sym.FactId, item: u16 },
    /// Anything else a condition reads: free to be either.
    free: *const ast.Expr,

    fn eql(a: Atom, b: Atom) bool {
        return switch (a) {
            .flag => |f| b == .flag and b.flag.eql(f),
            .is => |x| b == .is and b.is.fact.eql(x.fact) and b.is.value == x.value,
            .has => |x| b == .has and b.has.fact.eql(x.fact) and b.has.item == x.item,
            .free => false,
        };
    }
};

/// A condition in postfix over atoms.
pub const Op = union(enum) { atom: u8, not, both, either, yes, no };

pub const Formula = []const Op;

/// The atoms one quest's conditions are over, each once (but a free one).
pub const Atoms = struct {
    list: std.ArrayList(Atom) = .empty,

    fn index(a: *Atoms, arena: std.mem.Allocator, atom: Atom) error{ OutOfMemory, TooMany }!u8 {
        for (a.list.items, 0..) |had, i| if (had.eql(atom)) return @intCast(i); // safe: at most max_atoms
        if (a.list.items.len == max_atoms) return error.TooMany;
        try a.list.append(arena, atom);
        return @intCast(a.list.items.len - 1); // safe: at most max_atoms
    }
};

/// `e`, typed by the checker, as a formula over `atoms`; error.TooMany past max_atoms.
pub fn formula(arena: std.mem.Allocator, checked: *const check.Checked, atoms: *Atoms, e: *const ast.Expr) error{ OutOfMemory, TooMany }!Formula {
    var out: std.ArrayList(Op) = .empty;
    try into(arena, checked, atoms, e, &out);
    return out.items;
}

fn into(arena: std.mem.Allocator, checked: *const check.Checked, atoms: *Atoms, e: *const ast.Expr, out: *std.ArrayList(Op)) error{ OutOfMemory, TooMany }!void {
    switch (e.kind) {
        .boolean => |b| return out.append(arena, if (b) .yes else .no),
        .not => |inner| {
            try into(arena, checked, atoms, inner, out);
            return out.append(arena, .not);
        },
        .binary => |b| switch (b.op) {
            .@"and", .@"or" => {
                try into(arena, checked, atoms, b.lhs, out);
                try into(arena, checked, atoms, b.rhs, out);
                return out.append(arena, if (b.op == .@"and") .both else .either);
            },
            .eq, .ne, .has, .hasnt => if (try compared(arena, checked, atoms, b.op, b.lhs, b.rhs)) |i| {
                try out.append(arena, .{ .atom = i });
                if (b.op == .ne or b.op == .hasnt) try out.append(arena, .not);
                return;
            },
            else => {},
        },
        .name => if (factOf(checked, e)) |f| if (checked.facts[f.raw()].type == .boolean) {
            return out.append(arena, .{ .atom = try atoms.index(arena, .{ .flag = f }) });
        },
        else => {},
    }
    // what cannot be decided here is free
    if (constant(checked, e)) |b| return out.append(arena, if (b) .yes else .no);
    try out.append(arena, .{ .atom = try atoms.index(arena, .{ .free = e }) });
}

// A bool constant, where `e` names one.
fn constant(checked: *const check.Checked, e: *const ast.Expr) ?bool {
    const t = checked.exprs.get(e) orelse return null;
    const ref = t.ref orelse return null;
    if (ref != .constant) return null;
    const k = checked.consts[ref.constant.raw()].value;
    return if (k == .boolean) k.boolean else null;
}

// The fact `e` reads as it is: a plain fact, a section's own, or a role.
fn factOf(checked: *const check.Checked, e: *const ast.Expr) ?sym.FactId {
    const t = checked.exprs.get(e) orelse return null;
    const ref = t.ref orelse return null;
    return switch (ref) {
        .fact => |f| f,
        .own => |f| f,
        .role => |f| f,
        else => null,
    };
}

fn valueOf(checked: *const check.Checked, e: *const ast.Expr) ?u16 {
    const t = checked.exprs.get(e) orelse return null;
    const ref = t.ref orelse return null;
    return if (ref == .value) ref.value.index else null;
}

// `fact = value`, `fact has item` and their mirrors, as one atom; null for any other comparison.
fn compared(arena: std.mem.Allocator, checked: *const check.Checked, atoms: *Atoms, op: ast.Expr.Op, lhs: *const ast.Expr, rhs: *const ast.Expr) error{ OutOfMemory, TooMany }!?u8 {
    if (op == .has or op == .hasnt) {
        const f = factOf(checked, lhs) orelse return null;
        const item = valueOf(checked, rhs) orelse return null;
        return try atoms.index(arena, .{ .has = .{ .fact = f, .item = item } });
    }
    const f, const other = if (factOf(checked, lhs)) |f| .{ f, rhs } else if (factOf(checked, rhs)) |f| .{ f, lhs } else return null;
    if (checked.facts[f.raw()].type != .one_of) return null;
    const v = valueOf(checked, other) orelse return null;
    return try atoms.index(arena, .{ .is = .{ .fact = f, .value = v } });
}

/// Whether `f` holds where atom `i` is bit `i` of `bits`.
pub fn holds(f: Formula, bits: u64) bool {
    var stack: [64]bool = undefined;
    var n: usize = 0;
    for (f) |op| switch (op) {
        .atom => |i| {
            stack[n] = bits & (@as(u64, 1) << @intCast(i)) != 0; // safe: an atom is below max_atoms
            n += 1;
        },
        .yes, .no => {
            stack[n] = op == .yes;
            n += 1;
        },
        .not => stack[n - 1] = !stack[n - 1],
        .both, .either => {
            n -= 1;
            stack[n - 1] = if (op == .both) stack[n - 1] and stack[n] else stack[n - 1] or stack[n];
        },
    };
    return n == 1 and stack[0];
}

/// The atoms a formula reads, as bits.
pub fn reads(f: Formula) u64 {
    var bits: u64 = 0;
    for (f) |op| if (op == .atom) {
        bits |= @as(u64, 1) << @intCast(op.atom); // safe: an atom is below max_atoms
    };
    return bits;
}

// ---------------------------------------------------------------- how the story moves an atom

/// How an atom can move: up (become true), down, each with where the story does it first.
pub const Ways = struct { up: ?Span = null, down: ?Span = null };

/// Every effect of the story, by the fact it writes.
pub const Effects = struct {
    list: std.ArrayList(Effect) = .empty,
    /// By fact: where its effects are in `list`.
    of_fact: std.AutoHashMapUnmanaged(sym.FactId, std.ArrayList(u32)) = .empty,

    pub const Effect = struct {
        fact: sym.FactId,
        what: union(enum) { value: u16, flag: bool, add: u16, remove: u16, any },
        span: Span,
    };

    /// The effects of every section and part of `checked`.
    pub fn of(arena: std.mem.Allocator, checked: *const check.Checked) error{OutOfMemory}!Effects {
        var e: Effects = .{};
        for (checked.sections) |s| {
            try e.body(arena, checked, s.node.body);
            for (s.node.subsections) |p| try e.body(arena, checked, p.body);
        }
        return e;
    }

    fn body(e: *Effects, arena: std.mem.Allocator, checked: *const check.Checked, stmts: []const ast.Stmt) error{OutOfMemory}!void {
        for (stmts) |*st| switch (st.kind) {
            .line => |l| try e.body(arena, checked, l.effects),
            .choice => |ch| try e.body(arena, checked, ch.body),
            .cond => |k| {
                try e.body(arena, checked, k.body);
                try e.body(arena, checked, k.otherwise);
            },
            .gather => |g| if (g.then) |then| try e.body(arena, checked, then[0..1]),
            .effect => |*eff| try e.effect(arena, checked, eff, st.span),
            .flow, .flow_if => {},
        };
    }

    fn effect(e: *Effects, arena: std.mem.Allocator, checked: *const check.Checked, eff: *const ast.Effect, span: Span) error{OutOfMemory}!void {
        const name, const what: @FieldType(Effect, "what") = switch (eff.*) {
            .set => |*x| .{ &x.fact, if (valueOf(checked, &x.value)) |v| .{ .value = v } else if (x.value.kind == .boolean) .{ .flag = x.value.kind.boolean } else .any },
            .add => |*x| .{ &x.fact, if (valueOf(checked, &x.amount)) |v| .{ .add = v } else .any },
            .remove => |*x| .{ &x.fact, if (valueOf(checked, &x.amount)) |v| .{ .remove = v } else .any },
            .call => return,
        };
        const ref = checked.names.get(name) orelse return;
        const fact = switch (ref) {
            .fact, .own => |f| f,
            else => return,
        };
        const gop = try e.of_fact.getOrPut(arena, fact);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, @intCast(e.list.items.len)); // safe: effects are fewer than a u32
        try e.list.append(arena, .{ .fact = fact, .what = what, .span = span });
    }

    /// How the story can move `atom`: for a fact the game writes, any way.
    pub fn ways(e: *const Effects, checked: *const check.Checked, atom: Atom) Ways {
        const fact = switch (atom) {
            .flag => |f| f,
            .is => |x| x.fact,
            .has => |x| x.fact,
            .free => |x| return .{ .up = x.span, .down = x.span },
        };
        const f = checked.facts[fact.raw()];
        if (f.game) return .{ .up = f.span, .down = f.span };
        var w: Ways = .{};
        const mine = if (e.of_fact.get(fact)) |l| l.items else &.{};
        for (mine) |at| {
            const x = e.list.items[at];
            const up, const down = switch (atom) {
                .flag => switch (x.what) {
                    .flag => |b| .{ b, !b },
                    else => .{ true, true },
                },
                .is => |want| switch (x.what) {
                    .value => |v| .{ v == want.value, v != want.value },
                    else => .{ true, true },
                },
                .has => |want| switch (x.what) {
                    .add => |v| .{ v == want.item, false },
                    .remove => |v| .{ false, v == want.item },
                    .any => .{ true, true },
                    else => .{ false, false },
                },
                .free => unreachable, // unreachable: returned above
            };
            if (up and w.up == null) w.up = x.span;
            if (down and w.down == null) w.down = x.span;
        }
        return w;
    }
};

// ---------------------------------------------------------------- endings together

/// Whether `a` and `b` can hold at once, over atoms all free: `.yes` only where neither reads a free atom.
pub fn together(atoms: []const Atom, a: Formula, b: Formula) enum { yes, no, unknown } {
    const used = reads(a) | reads(b);
    if (@popCount(used) > max_together) return .unknown;
    var free = false;
    for (atoms, 0..) |x, i| if (used & (@as(u64, 1) << @intCast(i)) != 0 and x == .free) {
        free = true; // safe: an atom is below max_atoms
    };
    // every assignment of the atoms used, spread over their bits
    var sub: u64 = 0;
    while (true) {
        if (holds(a, sub) and holds(b, sub)) return if (free) .unknown else .yes;
        sub = (sub -% used) & used;
        if (sub == 0) return .no;
    }
}

test "a formula over a quest's atoms holds as its condition would" {
    const f: Formula = &.{ .{ .atom = 0 }, .{ .atom = 1 }, .not, .both };
    try std.testing.expect(holds(f, 0b01));
    try std.testing.expect(!holds(f, 0b11));
    try std.testing.expectEqual(@as(u64, 0b11), reads(f));
    const atoms = [_]Atom{ .{ .flag = .fromRaw(0) }, .{ .flag = .fromRaw(1) } };
    const g: Formula = &.{ .{ .atom = 1 }, .{ .atom = 0 }, .both };
    try std.testing.expect(together(&atoms, f, g) == .no);
    try std.testing.expect(together(&atoms, f, &.{.{ .atom = 0 }}) == .yes);
}
