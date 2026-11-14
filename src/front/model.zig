//! A quest's states, explored: what its atoms can be as the story moves
//! them one at a time, and which of its stages are reached in each. A stage
//! is reached once its condition holds, a live one while it holds, and the
//! quest ends at its first outcome or failure. From the states the story can
//! reach: one from which no ending can ever be is a stuck quest, found with
//! the way there; a stage reached in none can never be reached.

const std = @import("std");
const analysis = @import("analysis.zig");

const Atom = analysis.Atom;
const Formula = analysis.Formula;
const Ways = analysis.Ways;

pub const Model = struct {
    atoms: []const Atom,
    /// How each atom can move; a stage's own atom moves as the stage does.
    ways: []const Ways,
    /// Each stage of the quest: its condition, its atom where a condition reads it, and how it is reached.
    conds: []const Formula,
    atom_of: []const ?u8,
    live: []const bool,
    ends: []const bool,
};

/// One move of an atom, on the way to a state.
pub const Flip = struct { atom: u8, up: bool };

pub const Result = struct {
    /// Every state the story can reach was explored, within the bounds.
    complete: bool,
    /// The way to a state from which no ending can be, if there is one.
    stuck: ?[]const Flip = null,
    /// Each stage, whether some state reaches it.
    reached: []const bool = &.{},
};

const Stages = std.bit_set.Static(256);

const State = struct {
    facts: u64,
    stages: Stages,
    ended: bool,
};

const Key = struct { facts: u64, stages: [4]u64 };

fn keyOf(s: State) Key {
    return .{ .facts = s.facts, .stages = s.stages.masks };
}

/// Explores `m` from the story's start, every atom false; lists on `arena`, the exploration on `gpa`.
pub fn explore(gpa: std.mem.Allocator, arena: std.mem.Allocator, m: Model) error{OutOfMemory}!Result {
    var e: Explorer = .{ .gpa = gpa, .m = m };
    defer e.deinit();
    const first = e.closure(0, .empty) orelse return .{ .complete = false };
    _ = try e.visit(first, null, undefined) orelse return .{ .complete = false };
    var i: usize = 0;
    while (i < e.states.items.len) : (i += 1) {
        const s = e.states.items[i];
        e.edges_at.items[i] = @intCast(e.edges.items.len); // safe: below max_states times the atoms
        if (s.ended) continue;
        for (m.atoms, 0..) |_, a| {
            if (isStage(m, a)) continue;
            const bit = @as(u64, 1) << @intCast(a); // safe: below max_atoms
            const up = s.facts & bit == 0;
            const way = if (up) m.ways[a].up else m.ways[a].down;
            if (way == null) continue;
            const next = e.closure(s.facts ^ bit, s.stages) orelse return .{ .complete = false };
            const at = try e.visit(next, i, .{ .atom = @intCast(a), .up = up }) orelse return .{ .complete = false }; // safe: below max_atoms
            try e.edges.append(gpa, @intCast(at)); // safe: below max_states
        }
    }
    try e.edges_at.append(gpa, @intCast(e.edges.items.len)); // safe: below max_states times the atoms
    return e.result(arena);
}

fn isStage(m: Model, atom: usize) bool {
    for (m.atom_of) |a| if (a != null and a.? == atom) return true;
    return false;
}

const Explorer = struct {
    gpa: std.mem.Allocator,
    m: Model,
    states: std.ArrayList(State) = .empty,
    seen: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    /// How each state was first come to: its parent and the move.
    parents: std.ArrayList(?struct { from: u32, flip: Flip }) = .empty,
    edges: std.ArrayList(u32) = .empty,
    edges_at: std.ArrayList(u32) = .empty,

    fn deinit(e: *Explorer) void {
        e.states.deinit(e.gpa);
        e.seen.deinit(e.gpa);
        e.parents.deinit(e.gpa);
        e.edges.deinit(e.gpa);
        e.edges_at.deinit(e.gpa);
    }

    // The state's index, entered the first time it is come to; null past max_states.
    fn visit(e: *Explorer, s: State, from: ?usize, flip: Flip) error{OutOfMemory}!?usize {
        const gop = try e.seen.getOrPut(e.gpa, keyOf(s));
        if (gop.found_existing) return gop.value_ptr.*;
        if (e.states.items.len == analysis.max_states) return null;
        gop.value_ptr.* = @intCast(e.states.items.len); // safe: below max_states
        try e.states.append(e.gpa, s);
        try e.parents.append(e.gpa, if (from) |f| .{ .from = @intCast(f), .flip = flip } else null); // safe: below max_states
        try e.edges_at.append(e.gpa, 0);
        return e.states.items.len - 1;
    }

    // The atoms' bits with each stage's own atom set where it is reached.
    fn bits(e: *const Explorer, facts: u64, stages: Stages) u64 {
        var out = facts;
        for (e.m.atom_of, 0..) |a, k| if (a) |i| {
            const bit = @as(u64, 1) << @intCast(i); // safe: below max_atoms
            out = if (stages.isSet(k)) out | bit else out & ~bit;
        };
        return out;
    }

    // The stages reached once what holds settles, and whether the quest ended; null where live stages never settle.
    fn closure(e: *const Explorer, facts: u64, start: Stages) ?State {
        var stages = start;
        var rounds: usize = 0;
        while (rounds <= e.m.conds.len + 1) : (rounds += 1) {
            var changed = false;
            const now = e.bits(facts, stages);
            for (e.m.conds, 0..) |cond, k| {
                const holds = analysis.holds(cond, now);
                const was = stages.isSet(k);
                const next = if (e.m.live[k]) holds else was or holds;
                if (next == was) continue;
                stages.setValue(k, next);
                changed = true;
                if (next and e.m.ends[k]) return .{ .facts = facts, .stages = stages, .ended = true };
            }
            if (!changed) return .{ .facts = facts, .stages = stages, .ended = false };
        }
        return null;
    }

    fn result(e: *Explorer, arena: std.mem.Allocator) error{OutOfMemory}!Result {
        const n = e.states.items.len;
        // which states can still come to an ending: the ended, then whatever moves to one, until nothing more
        var ends: std.DynamicBitSetUnmanaged = try .initEmpty(e.gpa, n);
        defer ends.deinit(e.gpa);
        for (e.states.items, 0..) |s, i| if (s.ended) ends.set(i);
        var more = true;
        while (more) {
            more = false;
            for (0..n) |i| if (!ends.isSet(i)) for (e.edges.items[e.edges_at.items[i]..e.edges_at.items[i + 1]]) |to| if (ends.isSet(to)) {
                ends.set(i);
                more = true;
                break;
            };
        }
        const reached = try arena.alloc(bool, e.m.conds.len);
        @memset(reached, false);
        for (e.states.items) |s| for (reached, 0..) |*r, k| {
            r.* = r.* or s.stages.isSet(k);
        };
        // the first stuck state in the order they were come to is the nearest
        const stuck: ?[]const Flip = for (0..n) |i| {
            if (!ends.isSet(i)) break try e.path(arena, i);
        } else null;
        return .{ .complete = true, .stuck = stuck, .reached = reached };
    }

    fn path(e: *const Explorer, arena: std.mem.Allocator, to: usize) error{OutOfMemory}![]const Flip {
        var out: std.ArrayList(Flip) = .empty;
        var at = to;
        while (e.parents.items[at]) |p| {
            try out.append(arena, p.flip);
            at = p.from;
        }
        std.mem.reverse(Flip, out.items);
        return out.items;
    }
};

test "a quest whose ending needs what the story can take away for good gets stuck" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // atom 0 is a fact the story sets and never unsets; atom 1 one it can set and unset; atom 2 the stage `done`
    const atoms = [_]Atom{ .{ .flag = .fromRaw(0) }, .{ .flag = .fromRaw(1) }, .{ .flag = .fromRaw(2) } };
    const at: @import("riverrun-compiler").syntax.Span = .{ .file = 0, .start = 0, .end = 1 };
    const ways = [_]Ways{ .{ .up = at }, .{ .up = at, .down = at }, .{} };
    // `done when { b and not a }`: once `a` holds, it never can
    const stuck = try explore(std.testing.allocator, arena.allocator(), .{
        .atoms = &atoms,
        .ways = &ways,
        .conds = &.{&.{ .{ .atom = 1 }, .{ .atom = 0 }, .not, .both }},
        .atom_of = &.{2},
        .live = &.{false},
        .ends = &.{true},
    });
    try std.testing.expect(stuck.complete);
    try std.testing.expectEqual(@as(usize, 1), stuck.stuck.?.len);
    try std.testing.expectEqual(@as(u8, 0), stuck.stuck.?[0].atom);
    // `done when { b }`: always reachable
    const fine = try explore(std.testing.allocator, arena.allocator(), .{
        .atoms = &atoms,
        .ways = &ways,
        .conds = &.{&.{.{ .atom = 1 }}},
        .atom_of = &.{2},
        .live = &.{false},
        .ends = &.{true},
    });
    try std.testing.expect(fine.complete and fine.stuck == null and fine.reached[0]);
}
