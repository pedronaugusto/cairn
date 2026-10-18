//! cairn in a story's build: its problems reported inside riverrun's check,
//! where they are written, and its block written into the compiled story.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const cairn = @import("cairn");
const read_ = @import("read.zig");
const analysis = @import("analysis.zig");
const model = @import("model.zig");
const written = @import("written.zig");

const check_ = riverrun.check;
const compile_ = riverrun.compile;
const sym = check_.symbols;
const block = cairn.block;
const Read = read_.Read;

/// cairn's check of the whole story, which riverrun's check runs once its own are done: what only a quest as a
/// whole shows, at the place it is written.
pub fn check(_: ?*anyopaque, c: *check_.Checker, story: *const check_.Checked) error{OutOfMemory}!void {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try read_.read(a, story);
    for (r.problems) |p| try say(c, p);
    const effects: analysis.Effects = try .of(a, story);
    var stages: Stages = .empty;
    for (r.quests) |q| for (q.stages) |st| try stages.put(a, st.fact, st);
    for (r.quests) |q| try decide(c, a, story, &effects, &stages, q);
    try settles(c, a, story, r);
}

// Every quest's stages, by the fact each is.
const Stages = std.AutoHashMapUnmanaged(sym.FactId, read_.Stage);

fn say(c: *check_.Checker, p: read_.Problem) error{OutOfMemory}!void {
    switch (p.severity) {
        .err => try c.err(p.span, "{s}", .{p.message}),
        .warning => try c.warn(p.span, "{s}", .{p.message}),
    }
}

// ---------------------------------------------------------------- what is decided

// A quest's conditions as formulas over its atoms; null past the atoms' bound, when it is left unknown.
const Formulas = struct { atoms: analysis.Atoms, conds: []const analysis.Formula };

fn formulas(a: std.mem.Allocator, story: *const check_.Checked, q: read_.Quest) error{OutOfMemory}!?Formulas {
    var atoms: analysis.Atoms = .{};
    const conds = try a.alloc(analysis.Formula, q.stages.len);
    for (q.stages, conds) |st, *f| {
        const w = if (st.node.when) |*w| w else {
            f.* = &.{.no};
            continue;
        };
        f.* = analysis.formula(a, story, &atoms, w) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooMany => return null,
        };
    }
    return .{ .atoms = atoms, .conds = conds };
}

fn decide(c: *check_.Checker, a: std.mem.Allocator, story: *const check_.Checked, effects: *const analysis.Effects, stages: *const Stages, q: read_.Quest) error{OutOfMemory}!void {
    const f = try formulas(a, story, q) orelse return;
    // two endings that can hold at once would end the quest twice
    for (q.stages, 0..) |x, i| if (x.kind.ends()) for (q.stages[i + 1 ..], i + 1..) |y, j| if (y.kind.ends()) {
        if (analysis.together(f.atoms.list.items, f.conds[i], f.conds[j]) != .yes) continue;
        try c.err(y.node.name.span, "`{s}` and `{s}` can hold at once, and a quest ends once: make their conditions exclusive", .{ x.name, y.name });
    };
    const m = try modelOf(a, story, effects, stages, q, f);
    const out = try model.explore(c.gpa, a, m);
    if (!out.complete) return;
    const s = story.sections[q.section.raw()];
    // a quest with no ending is said to never end, not to get stuck
    const ends = for (q.stages) |st| {
        if (st.kind.ends()) break true;
    } else false;
    if (ends) if (out.stuck) |way| {
        try c.err(s.node.name.span, "`{s}` can get stuck{s}: no outcome or failure can be reached from there", .{ s.name, try describe(a, story, f.atoms.list.items, way) });
    };
    for (q.stages, out.reached) |st, reached| {
        if (reached or analysis.reads(f.conds[stageIndex(q, st)]) & freeBits(f.atoms.list.items) != 0) continue;
        try c.warn(st.node.name.span, "`{s}` can never be reached: nothing the story does makes its condition hold", .{st.name});
    }
}

fn stageIndex(q: read_.Quest, st: read_.Stage) usize {
    for (q.stages, 0..) |x, i| if (x.node == st.node) return i;
    return 0;
}

fn freeBits(atoms: []const analysis.Atom) u64 {
    var bits: u64 = 0;
    for (atoms, 0..) |x, i| if (x == .free) {
        bits |= @as(u64, 1) << @intCast(i); // safe: an atom is below max_atoms
    };
    return bits;
}

// The quest's model: each atom moves as the story moves it, another quest's stage as it is reached, and the quest's
// own as the model reaches it.
fn modelOf(a: std.mem.Allocator, story: *const check_.Checked, effects: *const analysis.Effects, stages: *const Stages, q: read_.Quest, f: Formulas) error{OutOfMemory}!model.Model {
    const atoms = f.atoms.list.items;
    const ways = try a.alloc(analysis.Ways, atoms.len);
    const atom_of = try a.alloc(?u8, q.stages.len);
    @memset(atom_of, null);
    for (atoms, ways, 0..) |x, *w, i| {
        w.* = effects.ways(story, x);
        if (x != .flag) continue;
        for (q.stages, atom_of) |st, *at| if (st.fact.eql(x.flag)) {
            at.* = @intCast(i); // safe: an atom is below max_atoms
        };
        if (stages.get(x.flag)) |other| w.* = .{ .up = other.node.name.span, .down = if (other.live) other.node.name.span else null };
    }
    const live = try a.alloc(bool, q.stages.len);
    const ends = try a.alloc(bool, q.stages.len);
    for (q.stages, live, ends) |st, *l, *e| {
        l.* = st.live;
        e.* = st.kind.ends();
    }
    return .{ .atoms = atoms, .ways = ways, .conds = f.conds, .atom_of = atom_of, .live = live, .ends = ends };
}

// The way to a stuck state, as a writer reads it: what moved, and where the story moves it.
fn describe(a: std.mem.Allocator, story: *const check_.Checked, atoms: []const analysis.Atom, way: []const model.Flip) error{OutOfMemory}![]const u8 {
    if (way.len == 0) return "";
    var out: std.Io.Writer.Allocating = .init(a);
    out.writer.writeAll(" once ") catch return error.OutOfMemory;
    for (way, 0..) |flip, i| {
        if (i > 0) out.writer.writeAll(if (i + 1 == way.len) " and " else ", ") catch return error.OutOfMemory;
        const x = atoms[flip.atom];
        const f = switch (x) {
            .flag => |id| id,
            .is => |v| v.fact,
            .has => |v| v.fact,
            .free => continue,
        };
        const name = story.facts[f.raw()].name;
        const items = switch (story.facts[f.raw()].type) {
            .one_of, .set_of => |e| story.enums[e.raw()].values,
            else => &.{},
        };
        (switch (x) {
            .flag => out.writer.print("`{s}` {s}", .{ name, if (flip.up) "holds" else "no longer holds" }),
            .is => |v| out.writer.print("`{s}` {s} `{s}`", .{ name, if (flip.up) "is" else "is no longer", items[v.value] }),
            .has => |v| out.writer.print("`{s}` {s} `{s}`", .{ name, if (flip.up) "has" else "no longer has", items[v.item] }),
            .free => unreachable, // unreachable: passed over above
        }) catch return error.OutOfMemory;
    }
    return out.written();
}

// Stages that read each other round through a live one could keep each other changing for ever: each set of
// stages that read each other round (Kosaraju's components) that holds a live one is refused.
fn settles(c: *check_.Checker, a: std.mem.Allocator, story: *const check_.Checked, r: Read) error{OutOfMemory}!void {
    var all: std.ArrayList(read_.Stage) = .empty;
    for (r.quests) |q| try all.appendSlice(a, q.stages);
    const n = all.items.len;
    var live = false;
    for (all.items) |st| live = live or st.live;
    if (!live) return;
    var by_fact: std.AutoHashMapUnmanaged(sym.FactId, u32) = .empty;
    for (all.items, 0..) |st, i| try by_fact.put(a, st.fact, @intCast(i)); // safe: stages are fewer than a u32
    const reads = try a.alloc([]const u32, n);
    const back = try a.alloc(std.ArrayList(u32), n);
    @memset(back, .empty);
    for (all.items, reads, 0..) |st, *out, i| {
        var list: std.ArrayList(u32) = .empty;
        var atoms: analysis.Atoms = .{};
        if (st.node.when) |*w| if (analysis.formula(a, story, &atoms, w)) |_| {} else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooMany => {},
        };
        for (atoms.list.items) |x| if (x == .flag) if (by_fact.get(x.flag)) |k| {
            try list.append(a, k);
            try back[k].append(a, @intCast(i)); // safe: stages are fewer than a u32
        };
        out.* = list.items;
    }
    const order = try finished(a, reads);
    const comp = try a.alloc(u32, n);
    @memset(comp, std.math.maxInt(u32));
    var stack: std.ArrayList(u32) = .empty;
    var i = order.len;
    while (i > 0) {
        i -= 1;
        const root = order[i];
        if (comp[root] != std.math.maxInt(u32)) continue;
        // the stages that come round to `root`, against the reads
        var members: std.ArrayList(u32) = .empty;
        try stack.append(a, root);
        comp[root] = root;
        while (stack.pop()) |v| {
            try members.append(a, v);
            for (back[v].items) |u| if (comp[u] == std.math.maxInt(u32)) {
                comp[u] = root;
                try stack.append(a, u);
            };
        }
        for (members.items) |v| if (all.items[v].live) {
            const loops = members.items.len > 1 or std.mem.findScalar(u32, reads[v], v) != null;
            if (!loops) continue;
            try c.err(all.items[v].node.name.span, "`{s}` is live and its condition comes back to it through other stages': they could keep changing each other for ever", .{all.items[v].name});
            break;
        };
    }
}

// Every stage in the order a depth-first walk of the reads finishes it.
fn finished(a: std.mem.Allocator, reads: []const []const u32) error{OutOfMemory}![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    const seen = try a.alloc(bool, reads.len);
    @memset(seen, false);
    var stack: std.ArrayList(struct { v: u32, next: u32 }) = .empty;
    for (0..reads.len) |start| {
        if (seen[start]) continue;
        seen[start] = true;
        try stack.append(a, .{ .v = @intCast(start), .next = 0 }); // safe: stages are fewer than a u32
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next == reads[top.v].len) {
                try out.append(a, top.v);
                _ = stack.pop();
                continue;
            }
            const u = reads[top.v][top.next];
            top.next += 1;
            if (seen[u]) continue;
            seen[u] = true;
            try stack.append(a, .{ .v = u, .next = 0 });
        }
    }
    return out.items;
}

// ---------------------------------------------------------------- the block

/// cairn's compile pass: its block, in the compiled story's ids.
pub fn compile(_: ?*anyopaque, c: *compile_.Compiler) compile_.Compiler.Error!void {
    const r = try read_.read(c.arena, c.checked);
    // what cairn's check refused never reaches here; said again, it refuses the story where it is written
    var refused = false;
    for (r.problems) |p| if (p.severity == .err) {
        try c.err(p.span, "{s}", .{p.message});
        refused = true;
    };
    if (refused) return error.PassFailed;
    if (r.quests.len == 0) return;
    if (r.quests.len > block.max_quests) {
        try c.err(.none, "the story has {d} quests, more than {d}", .{ r.quests.len, block.max_quests });
        return error.PassFailed;
    }
    const plan = try @import("emit.zig").plan(c, r);
    const bytes = try block.write(c.gpa, plan);
    defer c.gpa.free(bytes);
    try c.b.block(block.name, block.version, bytes);
}

test {
    _ = written;
}
