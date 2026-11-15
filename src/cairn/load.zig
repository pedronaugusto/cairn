//! A compiled story's quests, loaded: cairn's block read and checked against
//! the story it came with, every fact, section, thing and condition it names
//! held to what the story has, and what each stage's builtins read worked out
//! once, so a step never asks.

const std = @import("std");
const riverrun = @import("riverrun");
const block = @import("block.zig");

const story = riverrun.story;
const facts = riverrun.facts;

pub const Error = block.Error || error{
    /// The block is of another version than this cairn reads.
    WrongVersion,
    /// The block names a fact, a section, a thing or a condition the story does not have, or a fact of the wrong
    /// kind.
    NotThisStory,
};

/// What one stage reads besides its terms: its builtins' facts, each for the instance where it is kept per one.
pub const Also = struct { fact: facts.FactId, own: bool };

pub const Loaded = struct {
    plan: block.Plan,
    /// By quest and stage, in the plan's order: what each stage's condition's builtins read.
    also: []const []const []const Also,
    /// By quest: the calls of cairn's builtins it makes, by their index in the story.
    calls: []const []const u32,
};

/// The quests `s` holds, on `arena`; none where the story has no cairn block.
pub fn load(arena: std.mem.Allocator, s: *const story.Story) Error!Loaded {
    const found = s.block(block.name) orelse return .{ .plan = .{ .quests = &.{}, .calls = &.{}, .readers = .{ .starts = &.{}, .stages = &.{} } }, .also = &.{}, .calls = &.{} };
    if (found.version != block.version) return error.WrongVersion;
    const plan = try block.read(arena, found.bytes);
    if (plan.calls.len != s.len(.builtins)) return error.NotThisStory;
    if (plan.readers.starts.len != 0 and plan.readers.starts.len != s.len(.facts) + 1) return error.NotThisStory;
    for (plan.quests) |q| try quest(s, q);
    for (plan.calls) |c| try call(s, plan, c);
    const calls = try arena.alloc(std.ArrayList(u32), plan.quests.len);
    @memset(calls, .empty);
    for (plan.calls, 0..) |c, i| switch (c) {
        .none => {},
        inline .since, .before => |x| try calls[x.quest].append(arena, @intCast(i)), // safe: below max_calls
    };
    const by_quest = try arena.alloc([]const u32, plan.quests.len);
    for (by_quest, calls) |*out, l| out.* = l.items;
    const also = try arena.alloc([]const []const Also, plan.quests.len);
    for (also, plan.quests) |*out, q| {
        const stages = try arena.alloc([]const Also, q.stages.len);
        for (stages, q.stages) |*o, st| o.* = try alsoOf(arena, s, plan, q, st);
        out.* = stages;
    }
    return .{ .plan = plan, .also = also, .calls = by_quest };
}

fn fact(s: *const story.Story, raw: u16, kind: ?facts.Kind, keyed: ?bool) Error!facts.FactId {
    if (raw >= s.len(.facts)) return error.NotThisStory;
    const d = s.fact(.fromRaw(raw));
    if (kind) |k| if (d.kind != k) return error.NotThisStory;
    if (keyed) |k| if ((d.key != .none) != k) return error.NotThisStory;
    return .fromRaw(raw);
}

fn quest(s: *const story.Story, q: block.Quest) Error!void {
    if (q.section >= s.len(.sections) or s.section(.fromRaw(q.section)).kind != .other) return error.NotThisStory;
    const per: ?bool = q.repeat;
    const status = s.fact(try fact(s, q.status, .one_of, per));
    if (status.enumeration == null or s.items(status.enumeration.?).len < 4) return error.NotThisStory;
    if (q.current != block.none16) {
        const current = s.fact(try fact(s, q.current, .one_of, per));
        if (current.enumeration == null or s.items(current.enumeration.?).len < q.stages.len) return error.NotThisStory;
    }
    if (q.repeat != (q.count != block.none16)) return error.NotThisStory;
    if (q.repeat) _ = try fact(s, q.count, .int, false);
    for (q.roles) |r| _ = try fact(s, r, null, per);
    for (q.stages) |st| {
        if (st.section >= s.len(.sections)) return error.NotThisStory;
        _ = try fact(s, st.fact, .boolean, per);
        s.condition(.{ .start = st.when.start, .len = st.when.len }) catch return error.NotThisStory;
        for (st.active) |t| if (t >= s.len(.things)) return error.NotThisStory;
        for (st.keeps) |t| if (t >= s.len(.things)) return error.NotThisStory;
        for (st.roles) |r| _ = try fact(s, r.fact, null, null);
    }
}

fn call(s: *const story.Story, plan: block.Plan, c: block.Call) Error!void {
    switch (c) {
        .none => {},
        .since => |x| {
            const per: ?bool = plan.quests[x.quest].repeat;
            _ = try fact(s, x.fact, .int, null);
            _ = try fact(s, x.record, .int, per);
        },
        .before => |x| _ = try fact(s, x.latch, .boolean, plan.quests[x.quest].repeat),
    }
}

// What a stage's condition's builtins read: since's stage, record and fact (a clock waits in its heap instead),
// before's latch.
fn alsoOf(arena: std.mem.Allocator, s: *const story.Story, plan: block.Plan, q: block.Quest, st: block.Stage) Error![]const Also {
    var out: std.ArrayList(Also) = .empty;
    for (0..st.when.len) |k| {
        const t = s.term(st.when.start + @as(u32, @intCast(k))); // safe: below a u32 length
        if (t.op != .builtin) continue;
        switch (plan.calls[t.arg]) {
            .none => {},
            .since => |x| {
                try out.append(arena, .{ .fact = .fromRaw(q.stages[x.stage].fact), .own = q.repeat });
                try out.append(arena, .{ .fact = .fromRaw(x.record), .own = q.repeat });
                const f = s.fact(.fromRaw(x.fact));
                if (f.role != .clock) try out.append(arena, .{ .fact = .fromRaw(x.fact), .own = f.key != .none });
            },
            .before => |x| try out.append(arena, .{ .fact = .fromRaw(x.latch), .own = q.repeat }),
        }
    }
    return out.items;
}

const testing = @import("testing.zig");

test "a block that names what its story does not have is refused by name" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var fine = try testing.build(gpa, null);
    defer fine.deinit(gpa);
    const s: story.Story = try .init(fine.graph, .{});
    const loaded = try load(arena.allocator(), &s);
    try std.testing.expectEqual(@as(usize, 2), loaded.plan.quests[0].stages.len);
    const Damage = struct {
        var stages: [2]block.Stage = undefined;
        var quests: [1]block.Quest = undefined;
        // the second stage's condition is two terms of an `and` that has three
        fn condition(p: *block.Plan) void {
            quests[0] = p.quests[0];
            @memcpy(&stages, p.quests[0].stages);
            stages[1].when.len = 2;
            quests[0].stages = &stages;
            p.quests = &quests;
        }
        fn status(p: *block.Plan) void {
            quests[0] = p.quests[0];
            quests[0].status = quests[0].stages[0].fact;
            p.quests = &quests;
        }
    };
    for ([_]*const fn (*block.Plan) void{ Damage.condition, Damage.status }) |damage| {
        var bad = try testing.build(gpa, damage);
        defer bad.deinit(gpa);
        const b: story.Story = try .init(bad.graph, .{});
        try std.testing.expectError(error.NotThisStory, load(arena.allocator(), &b));
    }
}
