//! cairn's quests as riverrun's tools run them when a story is played
//! without its game (`riverrun play`): `Quests` over the played story's
//! facts, stepped whenever they change, as a game steps them, and what each
//! step did said as news: a quest started, a stage reached with its journal
//! lines and the effects the game applies, a live stage left, a quest ended
//! or failed, an activation key turned on or off. A quest that starts
//! itself and has roles is given the game's part: a stand-in thing for each
//! role, named for it, which the player names in `:set` and reads in the
//! transcript.
//!
//! The game's calls into cairn that change what the story tells are offered
//! to the player as the play's commands: `:start QUEST ROLE=THING…`, the
//! game's `start` of any quest with its roles (a repeat quest's next
//! instance each time), and `:bind QUEST ROLE=THING…`, the game's `bind` of
//! the roles of a quest that starts itself, before it does.

const std = @import("std");
const river = @import("riverrun-compiler");
const runtime = @import("riverrun");
const cairn = @import("cairn");

const facts = runtime.facts;
const story = runtime.story;
const run = runtime.run;

/// What `cairn.package` runs as a story is played.
pub const running: river.Running = .{ .name = "cairn", .start = start, .stop = stop, .builtins = builtins, .step = step, .bump = bump, .commands = &.{
    .{ .name = "start", .object = "quest", .help = "the game starts a quest, its roles given (a repeat quest's next instance)", .forms = everyQuest, .run = startQuest },
    .{ .name = "bind", .object = "quest", .help = "the game gives a quest that starts itself its roles, before it starts", .forms = selfStarting, .run = bindQuest },
} };

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
        else => return told.stopAt(q.metAt(), "a quest's stage met {s}", .{describe(e)}),
    };
    for (done.events) |e| switch (e.what) {
        .started => try told.say(.{ .what = "started", .name = try instanceName(told.arena, st, e.instance) }),
        .reached => |r| {
            var texts: [32]story.TextId = undefined;
            const lines = q.lines(e.instance.quest, r.stage, &texts);
            const words = try told.arena.alloc([]const u8, lines.len);
            for (words, lines) |*w, text| w.* = try told.arena.dupe(u8, q.say(st.words, e.instance, r.stage, text, .{}) catch |f| {
                if (f == error.OutOfMemory) return error.OutOfMemory;
                return told.stopAt(q.metAt(), "a journal line of `{s}` met {s}", .{ stageName(st, e.instance, r.stage), describe(f) });
            });
            try told.say(.{ .what = "reached", .name = try stageOf(told.arena, st, e.instance, r.stage), .words = words, .effects = r.effects, .written = r.written });
        },
        .left => |stage| try told.say(.{ .what = "left", .name = try stageOf(told.arena, st, e.instance, stage) }),
        .ended => |end| try told.say(.{ .what = if (end.failed) "failed" else "ended", .name = try stageOf(told.arena, st, e.instance, end.stage) }),
        .activated => |key| try told.say(.{ .what = "active", .name = key.name }),
        .deactivated => |key| try told.say(.{ .what = "inactive", .name = key.name }),
    };
}

// An error met evaluating, in words a writer acts on.
fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.Overflow => "a sum past what an int holds (64 bits)",
        error.QueryFailed, error.QueryWrongKind => "a query the game could not answer",
        error.BuiltinFailed, error.NoBuiltins => "a builtin that could not be answered",
        error.NoKey => "a fact kept per thing written for no thing",
        error.OutOfBounds => "a value past its fact's bounds",
        else => "an error",
    };
}

// Every quest: the game may start any, with its roles.
fn everyQuest(state: *anyopaque, a: std.mem.Allocator) error{OutOfMemory}![]const river.Running.Form {
    const st: *State = @ptrCast(@alignCast(state));
    const out = try a.alloc(river.Running.Form, st.quests.quests().len);
    for (out, st.quests.quests(), 0..) |*f, _, i| f.* = try formOf(a, st, .fromRaw(@intCast(i))); // safe: at most max_quests
    return out;
}

// The quests that start themselves and have roles, which the game gives them before they do.
fn selfStarting(state: *anyopaque, a: std.mem.Allocator) error{OutOfMemory}![]const river.Running.Form {
    const st: *State = @ptrCast(@alignCast(state));
    var out: std.ArrayList(river.Running.Form) = .empty;
    for (st.quests.quests(), 0..) |p, i| if (p.starts_itself and !p.repeat and p.roles.len > 0) try out.append(a, try formOf(a, st, .fromRaw(@intCast(i)))); // safe: at most max_quests
    return out.items;
}

// A quest by name, its roles each a parameter of its fact's type.
fn formOf(a: std.mem.Allocator, st: *const State, q: cairn.QuestId) error{OutOfMemory}!river.Running.Form {
    const p = st.quests.quests()[q.raw()];
    const params = try a.alloc(river.Running.Param, p.roles.len);
    for (params, p.roles) |*param, f| {
        const d = st.story.fact(.fromRaw(f));
        param.* = .{ .name = shortName(d.name), .type = .{ .kind = d.kind, .enumeration = d.enumeration, .ref_kind = d.ref_kind } };
    }
    return .{ .object = questName(st, q), .params = params };
}

// The quest a form names, found again by name (the forms are made anew for each play of the story).
fn questOf(st: *const State, forms: []const river.Running.Form, form: usize) cairn.QuestId {
    return st.quests.questNamed(forms[form].object).?;
}

fn startQuest(state: *anyopaque, form: usize, args: []const facts.Value, told: *river.Running.Told) error{ OutOfMemory, Refused, Stopped }!void {
    const st: *State = @ptrCast(@alignCast(state));
    const q = questOf(st, try everyQuest(state, told.arena), form);
    try rolesGiven(st, q, args, told);
    _ = st.quests.start(q, args) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AlreadyStarted => return told.refuse("`{s}` has started already: a quest that runs once starts once (a repeat quest starts as often as the game says)", .{questName(st, q)}),
        error.WrongRoles => return told.refuse("`{s}` takes its roles each a thing of its kind", .{questName(st, q)}),
        error.TooManyInstances => return told.refuse("`{s}` runs as many instances as cairn holds ({d})", .{ questName(st, q), cairn.Quests.max_runs }),
        else => return told.stop("cairn could not start `{s}` ({t})", .{ questName(st, q), e }),
    };
}

fn bindQuest(state: *anyopaque, form: usize, args: []const facts.Value, told: *river.Running.Told) error{ OutOfMemory, Refused, Stopped }!void {
    const st: *State = @ptrCast(@alignCast(state));
    const q = questOf(st, try selfStarting(state, told.arena), form);
    try rolesGiven(st, q, args, told);
    st.quests.bind(q, args) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AlreadyStarted => return told.refuse("`{s}` has started: a quest's roles are given before it starts", .{questName(st, q)}),
        error.WrongRoles => return told.refuse("`{s}` takes its roles each a thing of its kind", .{questName(st, q)}),
        else => return told.stop("cairn could not give `{s}` its roles ({t})", .{ questName(st, q), e }),
    };
    try told.say(.{ .what = "roles", .name = questName(st, q) });
}

// A role is a thing the game gives: none is no role.
fn rolesGiven(st: *const State, q: cairn.QuestId, args: []const facts.Value, told: *river.Running.Told) error{ OutOfMemory, Refused }!void {
    for (st.quests.quests()[q.raw()].roles, args) |f, v| if (v == .ref and v.ref == facts.Value.no_ref) {
        return told.refuse("`{s}` is a role: the game gives it a thing, never none", .{shortName(st.story.fact(.fromRaw(f)).name)});
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
