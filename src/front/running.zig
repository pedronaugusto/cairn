//! cairn's quests as riverrun's tools run them when a story is played
//! without its game (`riverrun play`): `Quests` over the played story's
//! facts, stepped whenever they change, as a game steps them, and what each
//! step did said as news: a quest started, a stage reached with its journal
//! lines and the effects the game applies, a live stage left, a quest ended
//! or failed, an activation key turned on or off. A quest that starts
//! itself and has roles is given the game's part: a stand-in thing for each
//! role, named for it, which the player names in `:set` and reads in the
//! transcript.

const std = @import("std");
const river = @import("riverrun-compiler");
const runtime = @import("riverrun");
const cairn = @import("cairn");

const facts = runtime.facts;
const story = runtime.story;
const run = runtime.run;

/// What `cairn.package` runs as a story is played.
pub const running: river.Running = .{ .name = "cairn", .start = start, .stop = stop, .builtins = builtins, .step = step, .bump = bump };

const State = struct {
    quests: cairn.Quests,
    story: *const story.Story,
    words: *const story.Strings,
};

fn start(gpa: std.mem.Allocator, game: river.Running.Game, told: *river.Running.Told) error{ OutOfMemory, Stopped }!?*anyopaque {
    if (game.story.block(cairn.block.name) == null) return null;
    const st = try gpa.create(State);
    errdefer gpa.destroy(st);
    st.* = .{ .quests = undefined, .story = game.story, .words = game.words };
    st.quests = cairn.Quests.init(gpa, game.story, game.store, game.host, game.owners, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return told.stop("cairn could not load the story's quests ({t}): this is cairn's fault, not the story's", .{e}),
    };
    errdefer st.quests.deinit();
    // the roles the game would give a quest that starts itself: a stand-in for each, named for its role
    const unbound = try told.arena.alloc(cairn.QuestId, st.quests.quests().len);
    for (st.quests.unbound(unbound)) |q| {
        const p = st.quests.quests()[q.raw()];
        const roles = try told.arena.alloc(facts.Value, p.roles.len);
        const words = try told.arena.alloc([]const u8, p.roles.len);
        for (roles, words, p.roles) |*v, *w, f| {
            const d = game.story.fact(.fromRaw(f));
            const name = shortName(d.name);
            v.* = if (d.kind == .ref) .{ .ref = try game.stand_in.give(game.stand_in.ctx, if (d.ref_kind) |k| game.story.refKind(k) else "", name) } else facts.Value.start(d.kind, d.bounds);
            w.* = try told.arena.print("{s} = {s}, standing in for the game's", .{ name, name });
        }
        st.quests.bind(q, roles) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return told.stop("cairn could not give `{s}` its roles ({t})", .{ questName(st, q), e }),
        };
        try told.say(.{ .what = "roles", .name = questName(st, q), .words = words });
    }
    return st;
}

fn stop(gpa: std.mem.Allocator, state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    st.quests.deinit();
    gpa.destroy(st);
}

fn builtins(state: *anyopaque) run.Builtins {
    const st: *State = @ptrCast(@alignCast(state));
    return st.quests.builtins();
}

fn bump(state: *anyopaque, family: []const u8, keyed: []const facts.Value) error{ OutOfMemory, Stopped }!void {
    const st: *State = @ptrCast(@alignCast(state));
    st.quests.bump(family, keyed) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Stopped;
}

// A step, as a game takes one after the facts changed, and each thing it did said.
fn step(state: *anyopaque, told: *river.Running.Told) error{ OutOfMemory, Stopped }!void {
    const st: *State = @ptrCast(@alignCast(state));
    const q = &st.quests;
    const done = q.step() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TwoEndings => return told.stop("a quest reached two of its endings at once: their conditions can hold together", .{}),
        error.NoFixedPoint => return told.stop("live stages kept changing each other for {d} rounds", .{cairn.max_rounds}),
        else => return told.stop("a quest's step stopped ({t})", .{e}),
    };
    for (done.events) |e| switch (e.what) {
        .started => try told.say(.{ .what = "started", .name = try instanceName(told.arena, st, e.instance) }),
        .reached => |r| {
            var texts: [32]story.TextId = undefined;
            const lines = q.lines(e.instance.quest, r.stage, &texts);
            const words = try told.arena.alloc([]const u8, lines.len);
            for (words, lines) |*w, text| w.* = try told.arena.dupe(u8, q.say(st.words, e.instance, r.stage, text, .{}) catch |f| {
                if (f == error.OutOfMemory) return error.OutOfMemory;
                return told.stop("a journal line of `{s}` could not be said ({t})", .{ stageName(st, e.instance, r.stage), f });
            });
            try told.say(.{ .what = "reached", .name = try stageOf(told.arena, st, e.instance, r.stage), .words = words, .effects = r.effects });
        },
        .left => |stage| try told.say(.{ .what = "left", .name = try stageOf(told.arena, st, e.instance, stage) }),
        .ended => |end| try told.say(.{ .what = if (end.failed) "failed" else "ended", .name = try stageOf(told.arena, st, e.instance, end.stage) }),
        .activated => |key| try told.say(.{ .what = "active", .name = key.name }),
        .deactivated => |key| try told.say(.{ .what = "inactive", .name = key.name }),
    };
}

fn questName(st: *const State, q: cairn.QuestId) []const u8 {
    return st.story.section(.fromRaw(st.quests.quests()[q.raw()].section)).name;
}

// A quest's instance by name: a repeat quest's numbered, `bounty(2)`.
fn instanceName(a: std.mem.Allocator, st: *const State, i: cairn.Instance) error{OutOfMemory}![]const u8 {
    const name = questName(st, i.quest);
    if (i.key == facts.Value.no_ref) return name;
    return a.print("{s}({d})", .{ name, i.key });
}

fn stageName(st: *const State, i: cairn.Instance, stage: cairn.StageId) []const u8 {
    return st.story.section(.fromRaw(st.quests.quests()[i.quest.raw()].stages[stage.raw()].section)).name;
}

// A stage of an instance by name: `the_stranger.noticed`, `bounty(2).tracked`.
fn stageOf(a: std.mem.Allocator, st: *const State, i: cairn.Instance, stage: cairn.StageId) error{OutOfMemory}![]const u8 {
    if (i.key == facts.Value.no_ref) return stageName(st, i, stage);
    return a.print("{s}.{s}", .{ try instanceName(a, st, i), shortName(stageName(st, i, stage)) });
}

fn shortName(name: []const u8) []const u8 {
    return if (std.mem.findScalarLast(u8, name, '.')) |dot| name[dot + 1 ..] else name;
}
