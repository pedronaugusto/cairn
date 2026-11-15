//! The plan cairn's block holds, in the compiled story's ids: each stage's
//! condition compiled into the story's terms (a shared stage once, for every
//! quest that inherits it), its activation keys made the story's things, what
//! each of cairn's builtin calls reads, and the dependency index.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const runtime = @import("riverrun");
const cairn = @import("cairn");
const read_ = @import("read.zig");
const written = @import("written.zig");

const compile_ = riverrun.compile;
const Compiler = compile_.Compiler;
const sym = riverrun.check.symbols;
const ast = riverrun.syntax.ast;
const block = cairn.block;
const Term = runtime.story.Term;
const Error = Compiler.Error;

/// `r`'s quests as cairn's block keeps them.
pub fn plan(c: *Compiler, r: read_.Read) Error!block.Plan {
    var e: Emitter = .{ .c = c };
    const quests = try c.arena.alloc(block.Quest, r.quests.len);
    for (quests, r.quests, 0..) |*out, q, i| out.* = try e.quest(q, @intCast(i)); // safe: at most max_quests
    return .{ .quests = quests, .calls = try e.calls(r), .readers = try e.readers(quests) };
}

const Emitter = struct {
    c: *Compiler,
    /// Each condition compiled once, by the part it is written on.
    conditions: std.AutoHashMapUnmanaged(*const ast.Subsection, block.Range) = .empty,
    /// The quest and stage each of a quest's own parts is, by the section it compiles to.
    parts: std.AutoHashMapUnmanaged(u32, block.StageRef) = .empty,

    fn fact(e: *const Emitter, id: sym.FactId) u16 {
        return e.c.fact(id).raw();
    }

    fn quest(e: *Emitter, q: read_.Quest, index: u24) Error!block.Quest {
        const a = e.c.arena;
        const roles = try a.alloc(u16, q.roles.len);
        for (roles, q.roles) |*out, f| out.* = e.fact(f);
        const stages = try a.alloc(block.Stage, q.stages.len);
        for (stages, q.stages, 0..) |*out, st, k| {
            out.* = try e.stage(st);
            out.inherited = !st.owner.eql(q.section);
            if (st.owner.eql(q.section)) try e.parts.put(a, out.section, .{ .quest = index, .stage = @intCast(k) }); // safe: at most max_stages
        }
        return .{
            .section = e.c.section(q.section).raw(),
            .repeat = q.repeat,
            .starts_itself = q.starts_itself,
            .status = e.fact(q.status),
            .current = if (q.current) |f| e.fact(f) else block.none16,
            .count = if (q.count) |f| e.fact(f) else block.none16,
            .roles = roles,
            .stages = stages,
        };
    }

    fn stage(e: *Emitter, st: read_.Stage) Error!block.Stage {
        const a = e.c.arena;
        const roles = try a.alloc(block.RoleRead, st.roles.len);
        for (roles, st.roles) |*out, x| out.* = .{ .fact = e.fact(x.fact), .role = x.role };
        return .{
            .section = (e.c.part(.{ .section = st.owner, .index = st.index }) orelse unreachable).raw(), // unreachable: a registered kind's parts compile to sections
            .fact = e.fact(st.fact),
            .when = try e.condition(st.node),
            .kind = st.kind,
            .live = st.live,
            .optional = st.optional,
            .after = st.after,
            .active = try e.keys(st.active),
            .keeps = try e.keys(st.keeps),
            .roles = roles,
        };
    }

    fn condition(e: *Emitter, p: *const ast.Subsection) Error!block.Range {
        if (e.conditions.get(p)) |r| return r;
        const w = if (p.when) |*w| w else unreachable; // unreachable: cairn's reader refuses a stage with no condition
        const r = try compile_.condition(e.c, w);
        const out: block.Range = .{ .start = r.start, .len = r.len };
        try e.conditions.put(e.c.arena, p, out);
        return out;
    }

    // Activation keys as the story's things of the kind `activation`, which the host resolves to its handles.
    fn keys(e: *Emitter, names: []const []const u8) Error![]const u32 {
        if (names.len == 0) return &.{};
        const kind = try e.c.b.refKind(written.activation);
        const out = try e.c.arena.alloc(u32, names.len);
        for (out, names) |*o, n| o.* = try e.c.b.thing(kind, n);
        return out;
    }

    // What each of the story's builtin calls reads, where it is cairn's: by the stage its part is and the fact the
    // quest keeps for it.
    fn calls(e: *Emitter, r: read_.Read) Error![]const block.Call {
        const b = e.c.b;
        const out = try e.c.arena.alloc(block.Call, b.builtins.items.len);
        for (out, b.builtins.items) |*o, call| {
            o.* = .none;
            if (!std.mem.eql(u8, str(b, call.kind), written.quest)) continue;
            const args = b.builtin_args.items[call.args.start..][0..call.args.len];
            const at = e.parts.get(args[0]) orelse continue;
            const q = r.quests[at.quest];
            if (std.mem.eql(u8, str(b, call.name), "since")) {
                for (q.calls) |x| if (x.what == .since and x.a == at.stage and e.fact(x.fact.?) == args[1]) {
                    o.* = .{ .since = .{ .quest = at.quest, .stage = at.stage, .fact = @intCast(args[1]), .record = e.fact(x.record) } }; // safe: a fact id is a u16
                };
            } else {
                const other = e.parts.get(args[1]) orelse continue;
                for (q.calls) |x| if (x.what == .before and x.a == at.stage and x.b == other.stage) {
                    o.* = .{ .before = .{ .quest = at.quest, .a = at.stage, .b = other.stage, .latch = e.fact(x.record) } };
                };
            }
        }
        return out;
    }

    fn str(b: *const runtime.story.Builder, s: runtime.story.format.Str) []const u8 {
        return b.names.items[s.offset..][0..s.len];
    }

    // For each fact, the stages whose conditions read it: a compressed sparse array, counted then filled.
    fn readers(e: *Emitter, quests: []const block.Quest) Error!block.Readers {
        const a = e.c.arena;
        const facts = e.c.b.facts.items.len;
        const starts = try a.alloc(u32, facts + 1);
        @memset(starts, 0);
        for (quests) |q| for (q.stages) |st| e.eachRead(st, starts, null, undefined);
        var total: u32 = 0;
        for (starts) |*s| {
            const n = s.*;
            s.* = total;
            total += n;
        }
        const stages = try a.alloc(block.StageRef, total);
        const fill = try a.dupe(u32, starts);
        for (quests, 0..) |q, i| for (q.stages, 0..) |st, k| e.eachRead(st, fill, stages, .{ .quest = @intCast(i), .stage = @intCast(k) }); // safe: at most max_quests, max_stages
        return .{ .starts = starts, .stages = stages };
    }

    // Each fact a stage's condition reads, once: counted into `at`, or written into `out` at it.
    fn eachRead(e: *const Emitter, st: block.Stage, at: []u32, out: ?[]block.StageRef, ref: block.StageRef) void {
        var seen: [64]u16 = undefined;
        var n: usize = 0;
        const terms = e.c.b.terms.items[st.when.start..][0..st.when.len];
        for (terms) |word| {
            const t: Term = @bitCast(word);
            const f: u16 = switch (t.op) {
                .fact, .keyed, .role, .happened => @intCast(t.arg), // safe: a fact id is a u16
                else => continue,
            };
            if (std.mem.findScalar(u16, seen[0..n], f) != null) continue;
            if (n < seen.len) {
                seen[n] = f;
                n += 1;
            }
            if (out) |o| {
                o[at[f]] = ref;
                at[f] += 1;
            } else at[f] += 1;
        }
    }
};
