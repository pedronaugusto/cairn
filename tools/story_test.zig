//! Stories compiled while cairn builds, through riverrun's `addStory` with
//! cairn registered as a game registers it, embedded, loaded and played:
//! WAKE's investigation to each of its endings, quest-givers who can be
//! killed, an order that matters, and a board of bounties. The game's
//! riverrun, cairn's and the stories' are one.

const std = @import("std");
const riverrun = @import("riverrun");
const cairn = @import("cairn");

const gpa = std.testing.allocator;
const facts = riverrun.facts;
const story_ = riverrun.story;
const run = riverrun.run;
const Value = facts.Value;

/// What the game knows that the story asks: people's names and its stock.
const World = struct {
    pelts: i64 = 0,

    fn name(_: *World, _: run.Context, who: u64) []const u8 {
        return switch (who) {
            41 => "Tom",
            42 => "Hilde",
            43 => "Sven",
            else => "someone",
        };
    }

    fn count(w: *World, _: run.Context, _: u64) i64 {
        return w.pelts;
    }

    fn resolve(_: ?*anyopaque, kind: []const u8, id: []const u8) ?u64 {
        if (std.mem.eql(u8, kind, "item_kind")) return 7;
        const keys = [_][]const u8{ "spawn_stranger", "pin_letter", "pin_target", "open_gate" };
        for (keys, 0..) |k, i| if (std.mem.eql(u8, k, id)) return 100 + i;
        return null;
    }
};

/// A story loaded and played: its facts in memory, the game bound, its quests run, each step's effects applied.
const Game = struct {
    story: story_.Story,
    words: story_.Strings,
    arena: std.heap.ArenaAllocator,
    memory: facts.Memory,
    world: World = .{},
    host: run.Host,
    owners: [facts.max_scopes]u64 = @splat(0),
    quests: cairn.Quests,
    /// Every event of the last step.
    last: []const cairn.Event = &.{},

    fn init(g: *Game, compiled: anytype) !void {
        g.* = .{ .story = try .init(compiled.graph, .{}), .words = try .init(compiled.words, .{}), .arena = .init(gpa), .memory = undefined, .host = undefined, .quests = undefined };
        g.memory = try .init(gpa, try g.story.schema(g.arena.allocator()));
        g.host = try .bind(gpa, &g.story, &g.world, .{ .name = World.name, .count = World.count }, null);
        try g.host.resolveStory(gpa, &g.story, .{ .user = null, .resolve = World.resolve }, null);
        g.quests = try .init(gpa, &g.story, g.memory.store(), &g.host, &g.owners, .{});
    }

    fn deinit(g: *Game) void {
        g.quests.deinit();
        g.host.deinit();
        g.memory.deinit();
        g.arena.deinit();
    }

    fn fact(g: *const Game, name: []const u8) facts.FactId {
        return g.story.factNamed(name).?;
    }

    fn quest(g: *const Game, name: []const u8) cairn.QuestId {
        return g.quests.questNamed(name).?;
    }

    fn stage(g: *const Game, q: []const u8, name: []const u8) cairn.StageId {
        return g.quests.stageNamed(g.quest(q), name).?;
    }

    /// A step, its effects applied as a host that applies them at once does.
    fn step(g: *Game) !void {
        const s = try g.quests.step();
        g.last = s.events;
        for (s.events) |e| if (e.what == .reached) for (e.what.reached.effects) |eff| {
            _ = try facts.apply(g.memory.store(), eff);
        };
    }

    /// How many events of the last step are of this kind.
    fn said(g: *const Game, what: std.meta.Tag(cairn.Event.What)) usize {
        var n: usize = 0;
        for (g.last) |e| n += @intFromBool(e.what == what);
        return n;
    }

    fn add(g: *Game, set: []const u8, item: u16) !void {
        var v = g.memory.get(g.fact(set)).set_of;
        v.set(item);
        try g.memory.set(g.fact(set), .{ .set_of = v });
    }

    fn activeNames(g: *const Game, out: [][]const u8) [][]const u8 {
        for (g.quests.activeSet(), 0..) |e, i| out[i] = e.key.name;
        return out[0..g.quests.activeSet().len];
    }
};

const wake = @import("wake");

test "WAKE: the stranger is named, from the letter and his hands" {
    var g: Game = undefined;
    try g.init(wake);
    defer g.deinit();
    const q = g.quest("the_stranger");
    const i: cairn.Instance = .{ .quest = q };
    // he starts himself, once the host has said who he is
    var unbound: [4]cairn.QuestId = undefined;
    try std.testing.expectEqual(@as(usize, 1), g.quests.unbound(&unbound).len);
    try g.quests.bind(q, &.{.{ .ref = 41 }});
    try g.step();
    try std.testing.expectEqual(cairn.Status.idle, g.quests.status(i));
    try g.memory.set(g.fact("met"), .{ .boolean = true });
    try g.step();
    try std.testing.expectEqual(cairn.Status.active, g.quests.status(i));
    try std.testing.expectEqual(@as(usize, 1), g.said(.started));
    try std.testing.expectEqual(g.stage("the_stranger", "noticed"), g.quests.current(i).?);
    var names: [8][]const u8 = undefined;
    try std.testing.expectEqualStrings("spawn_stranger", g.activeNames(&names)[0]);
    // the letter: the objective is reached, and its key replaces the noticed stage's
    try g.add("found", 0);
    try g.step();
    try std.testing.expect(g.quests.reached(i, g.stage("the_stranger", "the_letter")));
    try std.testing.expectEqual(@as(usize, 1), g.said(.deactivated));
    try std.testing.expectEqualStrings("pin_letter", g.activeNames(&names)[0]);
    // his hands, and in the same step the name, which the hands and the letter reach together
    try g.add("said", 1);
    try g.step();
    try std.testing.expectEqual(cairn.Status.done, g.quests.status(i));
    try std.testing.expectEqual(@as(usize, 0), g.quests.activeSet().len);
    try std.testing.expect(g.memory.get(g.fact("carried")).set_of.isSet(0));
    // the journal says what was found, in the order written, the stranger named
    var entries: [8]cairn.Entry = undefined;
    const journal = g.quests.journal(i, &entries);
    try std.testing.expectEqual(@as(usize, 4), journal.len);
    const named = g.stage("the_stranger", "named");
    var texts: [4]story_.TextId = undefined;
    const said = try g.quests.say(&g.words, i, named, g.quests.lines(q, named, &texts)[0], .{});
    try std.testing.expectEqualStrings("He was Tom, her son, from a life she didn't live.", said);
}

test "WAKE: he is gone at dawn, and it was late long before" {
    var g: Game = undefined;
    try g.init(wake);
    defer g.deinit();
    const q = g.quest("the_stranger");
    const i: cairn.Instance = .{ .quest = q };
    try g.quests.bind(q, &.{.{ .ref = 41 }});
    try g.memory.set(g.fact("hour"), .{ .int = 1 });
    try g.memory.set(g.fact("met"), .{ .boolean = true });
    try g.step();
    // `late` counts three hours from his being noticed, in the clock's heap
    try g.memory.set(g.fact("hour"), .{ .int = 3 });
    try g.step();
    try std.testing.expect(!g.quests.reached(i, g.stage("the_stranger", "late")));
    try g.memory.set(g.fact("hour"), .{ .int = 4 });
    try g.step();
    try std.testing.expect(g.quests.reached(i, g.stage("the_stranger", "late")));
    try g.memory.set(g.fact("hour"), .{ .int = 6 });
    try g.step();
    try std.testing.expectEqual(cairn.Status.failed, g.quests.status(i));
    try std.testing.expectEqual(@as(usize, 1), g.said(.ended));
    for (g.last) |e| if (e.what == .ended) try std.testing.expect(e.what.ended.failed);
}

const givers = @import("givers");

test "a quest-giver killed fails every quest he gave, and a quest that says otherwise keeps its own" {
    var g: Game = undefined;
    try g.init(givers);
    defer g.deinit();
    const hilde: Value = .{ .ref = 42 };
    const pelts = try g.quests.start(g.quest("pelts"), &.{.{ .ref = 43 }});
    const ring = try g.quests.start(g.quest("ring"), &.{hilde});
    const debt = try g.quests.start(g.quest("debt"), &.{hilde});
    const letter = try g.quests.start(g.quest("letter"), &.{});
    try g.step();
    try std.testing.expectEqual(@as(usize, 4), g.said(.started));
    var names: [8][]const u8 = undefined;
    try std.testing.expectEqualStrings("open_gate", g.activeNames(&names)[0]);
    // the pelts are counted by the game: until it bumps their stamp, nothing wakes
    g.world.pelts = 10;
    try g.step();
    try std.testing.expectEqual(cairn.Status.active, g.quests.status(pelts));
    try g.quests.bump("stock", &.{.{ .ref = 7 }});
    try g.step();
    try std.testing.expectEqual(cairn.Status.done, g.quests.status(pelts));
    // Hilde dies: what she gave fails, the debt she was owed is settled by it, and the rest go on
    try g.memory.setKey(g.fact("dead"), 42, .{ .boolean = true });
    try g.step();
    try std.testing.expectEqual(cairn.Status.failed, g.quests.status(ring));
    try std.testing.expectEqual(cairn.Status.done, g.quests.status(debt));
    try std.testing.expectEqual(g.stage("debt", "abandoned"), g.quests.current(debt).?);
    try std.testing.expectEqual(cairn.Status.active, g.quests.status(letter));
    try std.testing.expectEqual(@as(usize, 0), g.quests.activeSet().len);
    // the shared stage's words name the quest's own giver
    const abandoned = g.stage("ring", "abandoned");
    var texts: [2]story_.TextId = undefined;
    const said = try g.quests.say(&g.words, ring, abandoned, g.quests.lines(ring.quest, abandoned, &texts)[0], .{});
    try std.testing.expectEqualStrings("Nobody else will pay for this: Hilde is dead.", said);
}

const order = @import("order");

test "order matters: told before he found out is trusted, after is betrayed" {
    for ([_]bool{ true, false }) |told_first| {
        var g: Game = undefined;
        try g.init(order);
        defer g.deinit();
        const i: cairn.Instance = .{ .quest = g.quest("confession") };
        const first, const second = if (told_first) .{ "told_her", "he_found_out" } else .{ "he_found_out", "told_her" };
        try g.memory.set(g.fact(first), .{ .boolean = true });
        try g.step();
        try std.testing.expectEqual(cairn.Status.active, g.quests.status(i));
        try g.memory.set(g.fact(second), .{ .boolean = true });
        try g.step();
        try std.testing.expectEqual(if (told_first) cairn.Status.done else cairn.Status.failed, g.quests.status(i));
    }
}

test "order matters: `since` counts days from the telling, whatever the days were before" {
    var g: Game = undefined;
    try g.init(order);
    defer g.deinit();
    const i: cairn.Instance = .{ .quest = g.quest("confession") };
    try g.memory.set(g.fact("days"), .{ .int = 5 });
    try g.memory.set(g.fact("told_her"), .{ .boolean = true });
    try g.step();
    try g.memory.set(g.fact("days"), .{ .int = 6 });
    try g.step();
    try std.testing.expect(!g.quests.reached(i, g.stage("confession", "waited")));
    try g.memory.set(g.fact("days"), .{ .int = 7 });
    try g.step();
    try std.testing.expect(g.quests.reached(i, g.stage("confession", "waited")));
}

const bounties = @import("bounties");

test "a board of bounties: each instance its own target, claimed or expired alone" {
    var g: Game = undefined;
    try g.init(bounties);
    defer g.deinit();
    const q = g.quest("bounty");
    var board: [3]cairn.Instance = undefined;
    for (&board, [_]u64{ 41, 42, 43 }) |*b, target| b.* = try g.quests.start(q, &.{.{ .ref = target }});
    try std.testing.expectEqual(@as(u64, 2), board[1].key);
    try g.step();
    try std.testing.expectEqual(@as(usize, 3), g.said(.started));
    try std.testing.expectEqual(@as(usize, 3), g.quests.activeSet().len);
    // the player follows the second: its own fact, written for it alone
    try g.memory.setKey(g.fact("bounty.tracked"), board[1].key, .{ .boolean = true });
    try g.step();
    try std.testing.expect(g.quests.reached(board[1], g.stage("bounty", "tracking")));
    try std.testing.expect(!g.quests.reached(board[0], g.stage("bounty", "tracking")));
    // the second's target dies: only its conditions wake, and it is claimed
    try g.memory.setKey(g.fact("dead"), 42, .{ .boolean = true });
    try g.step();
    try std.testing.expect(g.quests.watch.evaluated.items.len <= 2);
    try std.testing.expectEqual(cairn.Status.done, g.quests.status(board[1]));
    try std.testing.expectEqual(@as(i64, 50), g.memory.get(g.fact("gold")).int);
    // four days on, the others expire, each in its clock's heap
    try g.memory.set(g.fact("day"), .{ .int = 4 });
    try g.step();
    try std.testing.expectEqual(cairn.Status.failed, g.quests.status(board[0]));
    try std.testing.expectEqual(cairn.Status.failed, g.quests.status(board[2]));
    try std.testing.expectEqual(@as(usize, 0), g.quests.activeSet().len);
    try std.testing.expectEqual(@as(u64, 3), g.quests.started(q));
}

test "a board of bounties saved and restored: the active set comes back from the facts" {
    var g: Game = undefined;
    try g.init(bounties);
    defer g.deinit();
    const q = g.quest("bounty");
    _ = try g.quests.start(q, &.{.{ .ref = 41 }});
    const second = try g.quests.start(q, &.{.{ .ref = 42 }});
    try g.step();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const world = g.memory.schema.scopeNamed("world").?;
    try facts.snapshot.write(&g.memory, &out.writer, world, g.story.hash());
    // another game, the save loaded into it
    var h: Game = undefined;
    try h.init(bounties);
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = try facts.snapshot.read(&h.memory, arena.allocator(), world, h.story.hash(), out.written());
    try h.quests.restored();
    try std.testing.expectEqual(@as(usize, 2), h.quests.activeSet().len);
    try std.testing.expectEqual(cairn.Status.active, h.quests.status(second));
    try h.memory.setKey(h.fact("dead"), 42, .{ .boolean = true });
    try h.step();
    try std.testing.expectEqual(cairn.Status.done, h.quests.status(second));
    try std.testing.expectEqual(@as(usize, 1), h.quests.activeSet().len);
}
