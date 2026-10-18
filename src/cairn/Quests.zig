//! A story's quests, run over riverrun's facts: each instance's stages
//! reached as their conditions come to hold, its endings, the active set and
//! the journal. Every condition is watched by riverrun's `Watch` for the
//! instance it is for, with its roles, so a step evaluates only what read
//! what changed; a stage reached stops being watched, unless it is live, and
//! an instance that ends stops costing anything.
//!
//! Everything cairn keeps is the story's facts: each stage reached, each
//! instance's status, current stage and roles, what `since` and `before`
//! record. So a save of the facts is a save of the quests; on a restore,
//! `restored` builds the rest again from them, and a stage whose condition
//! holds (one a patch added, or fixed) is reached at the first step. The
//! active set and the journal are derived from the facts, never kept apart.
//!
//! cairn writes its own facts at once, as riverrun writes visits; what a stage
//! does (its effects) is emitted, never applied, and seen at the next step.

const std = @import("std");
const riverrun = @import("riverrun");
const block = @import("block.zig");
const load_ = @import("load.zig");
const Active = @import("Active.zig");

const Quests = @This();
const facts = riverrun.facts;
const story_ = riverrun.story;
const run = riverrun.run;
const react = riverrun.react;
const Value = facts.Value;
const Kind = block.Kind;

const ids = @import("ids.zig");
pub const QuestId = ids.QuestId;
pub const StageId = ids.StageId;
pub const Instance = ids.Instance;

pub const Status = enum { idle, active, done, failed };

/// The most rounds a step takes to a fixed point: cairn's own writes waking further stages.
pub const max_rounds = 64;
/// The most instances run at once.
pub const max_runs = 1 << 24;

pub const Error = react.Watch.Error || load_.Error || error{
    /// The host is not bound to the story, or has not resolved the things it names.
    HostNotBound,
    /// `start` for a quest already started, or `bind` for one already given its roles.
    AlreadyStarted,
    /// Roles not of the quest's kinds, or not as many as it has.
    WrongRoles,
    /// A quest's instance reached two endings in one step: their conditions can hold at once.
    TwoEndings,
    /// A step went `max_rounds` rounds and stages still changed: live stages keep changing each other.
    NoFixedPoint,
    /// More than `max_runs` instances at once.
    TooManyInstances,
};

pub const Options = struct {
    /// The most conditions one step evaluates; null for all that may have changed. A budget changes when a stage
    /// is reached, never what is.
    budget: ?u32 = null,
};

/// What happened to an instance in a step.
pub const Event = struct {
    instance: Instance,
    what: What,

    pub const What = union(enum) {
        started,
        /// A stage reached, and what reaching it does: its effects, emitted for the host to apply.
        reached: struct { stage: StageId, effects: []const facts.Effect },
        /// A live stage whose condition no longer holds.
        left: StageId,
        /// The instance ended, at an outcome or a failure.
        ended: struct { stage: StageId, failed: bool },
        /// A key of the active set, added or taken away.
        activated: Active.Key,
        deactivated: Active.Key,
    };
};

/// What a step did, valid until the next step.
pub const Step = struct { events: []const Event };

/// A journal entry: a stage reached, or an objective open.
pub const Entry = struct { stage: StageId, kind: Kind, open: bool };

// One instance being run: what is watched for it.
const Run = struct {
    quest: u32,
    key: u64,
    status: Status,
    /// By stage: its condition, while it is watched.
    conds: []?react.CondId,
    used: bool,
};

gpa: std.mem.Allocator,
story: *const story_.Story,
store: facts.Store,
host: *const run.Host,
owners: *const [facts.max_scopes]u64,
options: Options,
/// Holds the plan, read from the story.
arena: *std.heap.ArenaAllocator,
loaded: load_.Loaded,
/// On `arena`, so a builtin's answer finds it however `Quests` moves.
answers: *Answers,
watch: react.Watch,
/// A quest that runs once is run `quest`; a repeat quest's instances follow.
runs: std.ArrayList(Run) = .empty,
free: std.ArrayList(u32) = .empty,
active: Active = .{},
/// Events the host's own `start` made, said at the next step.
queued: std.ArrayList(Event) = .empty,
events: std.ArrayList(Event) = .empty,
/// What a step's reached stages do, valid until the next step.
step_arena: std.heap.ArenaAllocator,
/// What `say` writes, valid until the next.
say_arena: std.heap.ArenaAllocator,
pending: std.ArrayList(Change) = .empty,
/// How many conditions the steps have evaluated, in all: what a host measures a budget by.
evaluations: u64 = 0,

const Change = struct { run: u32, stage: u8, reach: bool };

/// The quests of `s` over `store`, as its facts hold them: a new game's, or a save's. The story, store, host and
/// owners outlive it.
pub fn init(gpa: std.mem.Allocator, s: *const story_.Story, store: facts.Store, host: *const run.Host, owners: *const [facts.max_scopes]u64, options: Options) Error!Quests {
    if (!host.serves(s)) return error.HostNotBound;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const loaded = try load_.load(arena.allocator(), s);
    const answers = try arena.allocator().create(Answers);
    var q: Quests = .{
        .gpa = gpa,
        .story = s,
        .store = store,
        .host = host,
        .owners = owners,
        .options = options,
        .arena = arena,
        .loaded = loaded,
        .answers = answers,
        .watch = undefined,
        .step_arena = .init(gpa),
        .say_arena = .init(gpa),
    };
    answers.* = .{ .loaded = &q.loaded, .store = store, .story = s };
    q.watch = try .init(gpa, s, store, host, owners, .{ .builtins = q.builtins() });
    errdefer q.deinitRuns();
    try q.rebuild();
    // the plan moves with `q`: what answers the builtins holds its own copy
    const kept = try arena.allocator().create(load_.Loaded);
    kept.* = q.loaded;
    answers.loaded = kept;
    return q;
}

pub fn deinit(q: *Quests) void {
    q.deinitRuns();
    q.arena.deinit();
    q.gpa.destroy(q.arena);
    q.step_arena.deinit();
    q.say_arena.deinit();
    q.* = undefined;
}

fn deinitRuns(q: *Quests) void {
    const gpa = q.gpa;
    for (q.runs.items) |r| gpa.free(r.conds);
    q.runs.deinit(gpa);
    q.free.deinit(gpa);
    q.active.deinit(gpa);
    q.queued.deinit(gpa);
    q.events.deinit(gpa);
    q.pending.deinit(gpa);
    q.watch.deinit();
}

// What answers cairn's builtins: the loaded plan and the store, where they stay while the quests move.
const Answers = struct { loaded: *const load_.Loaded, store: facts.Store, story: *const story_.Story };

fn builtins(q: *const Quests) run.Builtins {
    return .{ .user = q.answers, .call = answer };
}

/// After the host restored the facts (a save loaded, a moment gone back to): everything cairn keeps beside the
/// facts is built again from them. Nothing is said of it: the active set is what `active` gives now.
pub fn restored(q: *Quests) Error!void {
    const watch: react.Watch = try .init(q.gpa, q.story, q.store, q.host, q.owners, .{ .builtins = q.builtins() });
    q.deinitRuns();
    q.watch = watch;
    q.runs = .empty;
    q.free = .empty;
    q.active = .{};
    q.queued = .empty;
    q.events = .empty;
    q.pending = .empty;
    try q.rebuild();
}

// ---------------------------------------------------------------- the story's quests

pub fn quests(q: *const Quests) []const block.Quest {
    return q.loaded.plan.quests;
}

fn plan(q: *const Quests, quest: QuestId) block.Quest {
    return q.loaded.plan.quests[quest.raw()];
}

/// A quest by its qualified name, `module.name`.
pub fn questNamed(q: *const Quests, name: []const u8) ?QuestId {
    for (q.loaded.plan.quests, 0..) |p, i| if (std.mem.eql(u8, q.story.section(.fromRaw(p.section)).name, name)) return .fromRaw(@intCast(i)); // safe: at most max_quests
    return null;
}

/// A stage of `quest` by its name in the quest.
pub fn stageNamed(q: *const Quests, quest: QuestId, name: []const u8) ?StageId {
    for (q.plan(quest).stages, 0..) |st, k| {
        const full = q.story.section(.fromRaw(st.section)).name;
        const dot = std.mem.findScalarLast(u8, full, '.') orelse continue;
        if (std.mem.eql(u8, full[dot + 1 ..], name)) return .fromRaw(@intCast(k)); // safe: at most max_stages
    }
    return null;
}

/// The stages that read `fact` in their conditions: the story's dependency index, for tools.
pub fn readers(q: *const Quests, fact: facts.FactId) []const block.StageRef {
    return q.loaded.plan.readers.of(fact.raw());
}

/// The quests that start themselves and are given roles: the host binds them (`bind`) before they can.
pub fn unbound(q: *const Quests, out: []QuestId) []QuestId {
    var n: usize = 0;
    for (q.loaded.plan.quests, 0..) |p, i| {
        if (!p.starts_itself or p.roles.len == 0 or n == out.len) continue;
        if (q.runs.items[i].status == .idle and !q.bound(@intCast(i))) { // safe: at most max_quests
            out[n] = .fromRaw(@intCast(i)); // safe: at most max_quests
            n += 1;
        }
    }
    return out[0..n];
}

// ---------------------------------------------------------------- reading an instance

fn readFact(q: *const Quests, raw: u16, key: u64) Value {
    return readIn(q.story, q.store, raw, key);
}

// A fact, for the instance `key` where it is kept per one.
fn readIn(s: *const story_.Story, store: facts.Store, raw: u16, key: u64) Value {
    const f: facts.FactId = .fromRaw(raw);
    if (s.fact(f).key == .none) return store.get(f);
    if (key == Value.no_ref) return .initial(s.fact(f).kind);
    return store.getKey(f, key);
}

fn writeFact(q: *Quests, raw: u16, key: u64, v: Value) Error!void {
    const f: facts.FactId = .fromRaw(raw);
    if (q.story.fact(f).key == .none) return q.store.set(f, v);
    return q.store.setKey(f, key, v);
}

/// Where an instance has got: idle until it starts, then active until it ends.
pub fn status(q: *const Quests, i: Instance) Status {
    const v = q.readFact(q.plan(i.quest).status, i.key).one_of;
    return switch (v) {
        0 => .active,
        1 => .done,
        2 => .failed,
        else => .idle,
    };
}

/// Whether the instance has reached the stage.
pub fn reached(q: *const Quests, i: Instance, stage: StageId) bool {
    return q.readFact(q.plan(i.quest).stages[stage.raw()].fact, i.key).boolean;
}

/// The stage the instance reached last, while it is reached.
pub fn current(q: *const Quests, i: Instance) ?StageId {
    const p = q.plan(i.quest);
    if (p.current == block.none16) return null;
    const v = q.readFact(p.current, i.key).one_of;
    return if (v < p.stages.len) .fromRaw(@intCast(v)) else null; // safe: below max_stages
}

/// The value the instance was given for its quest's role `role`.
pub fn role(q: *const Quests, i: Instance, which: usize) Value {
    return q.readFact(q.plan(i.quest).roles[which], i.key);
}

/// How many instances a repeat quest has started: its instances are keyed 1 to this.
pub fn started(q: *const Quests, quest: QuestId) u64 {
    const p = q.plan(quest);
    if (!p.repeat) return @intFromBool(q.status(.{ .quest = quest }) != .idle);
    return @intCast(@max(0, q.store.get(.fromRaw(p.count)).int)); // safe: a count is never negative
}

/// The active set: every key an active instance keeps active now, valid until the next step.
pub fn activeSet(q: *const Quests) []const Active.Entry {
    return q.active.list.items;
}

// ---------------------------------------------------------------- starting

/// Starts a quest with its roles, in the order its `(role)` facts are written: a repeat quest's new instance,
/// keyed by the next of its count, or the one run of a quest that runs once. Its stages are evaluated at the next
/// step, which says it started.
pub fn start(q: *Quests, quest: QuestId, roles: []const Value) Error!Instance {
    const p = q.plan(quest);
    try q.fits(p, roles);
    var key: u64 = Value.no_ref;
    if (p.repeat) {
        const n = q.store.get(.fromRaw(p.count)).int + 1;
        try q.store.set(.fromRaw(p.count), .{ .int = n });
        key = @intCast(n); // safe: a count starts at 1
    } else if (q.status(.{ .quest = quest }) != .idle) return error.AlreadyStarted;
    const i: Instance = .{ .quest = quest, .key = key };
    for (p.roles, roles) |f, v| try q.writeFact(f, key, v);
    try q.writeFact(p.status, key, .{ .one_of = 0 });
    const r = if (p.repeat) try q.newRun(quest.raw(), key) else quest.raw();
    q.runs.items[r].status = .active;
    try q.watchAll(r);
    try q.queued.append(q.gpa, .{ .instance = i, .what = .started });
    return i;
}

/// Gives a quest that starts itself its roles, after which it starts when one of its first stages is reached.
pub fn bind(q: *Quests, quest: QuestId, roles: []const Value) Error!void {
    const p = q.plan(quest);
    try q.fits(p, roles);
    if (p.repeat or q.status(.{ .quest = quest }) != .idle) return error.AlreadyStarted;
    for (p.roles, roles) |f, v| try q.writeFact(f, Value.no_ref, v);
    try q.unwatch(quest.raw());
    try q.watchStarts(quest.raw());
}

fn fits(q: *const Quests, p: block.Quest, roles: []const Value) Error!void {
    if (roles.len != p.roles.len) return error.WrongRoles;
    for (p.roles, roles) |f, v| if (@as(facts.Kind, v) != q.story.fact(.fromRaw(f)).kind) return error.WrongRoles;
}

// Whether a quest that runs once holds a value for every role.
fn bound(q: *const Quests, quest: u32) bool {
    for (q.loaded.plan.quests[quest].roles) |f| {
        const v = q.store.get(.fromRaw(f));
        if (v.eql(.initial(@as(facts.Kind, v)))) return false;
    }
    return true;
}

fn newRun(q: *Quests, quest: u32, key: u64) Error!u32 {
    const stages = q.loaded.plan.quests[quest].stages.len;
    const conds = try q.gpa.alloc(?react.CondId, stages);
    errdefer q.gpa.free(conds);
    @memset(conds, null);
    const r: Run = .{ .quest = quest, .key = key, .status = .idle, .conds = conds, .used = true };
    const at: u32 = if (q.free.pop()) |f| f else blk: {
        if (q.runs.items.len == max_runs) return error.TooManyInstances;
        try q.runs.append(q.gpa, undefined);
        break :blk @intCast(q.runs.items.len - 1); // safe: below max_runs
    };
    q.runs.items[at] = r;
    return at;
}

// ---------------------------------------------------------------- watching

fn instanceOf(q: *const Quests, r: u32) Instance {
    const x = q.runs.items[r];
    return .{ .quest = .fromRaw(x.quest), .key = x.key };
}

// The roles a stage's terms read, as the instance was given them (its facts keep them): the quest's own, or a shared
// stage's read as the quest's.
fn rolesFor(q: *const Quests, a: std.mem.Allocator, i: Instance, st: block.Stage) error{OutOfMemory}![]const run.Role {
    const out = try a.alloc(run.Role, st.roles.len);
    for (out, st.roles) |*o, x| o.* = .{ .fact = .fromRaw(x.fact), .value = q.role(i, x.role) };
    return out;
}

fn watchStage(q: *Quests, r: u32, k: u8) Error!void {
    const x = q.runs.items[r];
    if (x.conds[k] != null) return;
    const st = q.loaded.plan.quests[x.quest].stages[k];
    var buf: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buf);
    const roles = try q.rolesFor(fixed.allocator(), q.instanceOf(r), st);
    const also = q.loaded.also[x.quest][k];
    const reads = try fixed.allocator().alloc(react.Read, also.len);
    for (reads, also) |*o, a| o.* = .{ .fact = a.fact, .key = if (a.own and x.key != Value.no_ref) x.key else null };
    const when: story_.Range = .{ .start = st.when.start, .len = st.when.len };
    q.runs.items[r].conds[k] = try q.watch.add(when, r << 8 | k, .{ .this = x.key, .roles = roles, .also = reads });
}

// Every stage of an active run that can still change: those not reached, and the live.
fn watchAll(q: *Quests, r: u32) Error!void {
    const x = q.runs.items[r];
    const p = q.loaded.plan.quests[x.quest];
    const i = q.instanceOf(r);
    for (p.stages, 0..) |st, k| if (st.live or !q.reached(i, .fromRaw(@intCast(k)))) try q.watchStage(r, @intCast(k)); // safe: at most max_stages
}

// The stages a quest that starts itself starts at: those with no `after`.
fn watchStarts(q: *Quests, r: u32) Error!void {
    const p = q.loaded.plan.quests[q.runs.items[r].quest];
    for (p.stages, 0..) |st, k| if (st.after.len == 0) try q.watchStage(r, @intCast(k)); // safe: at most max_stages
}

fn unwatchStage(q: *Quests, r: u32, k: u8) Error!void {
    const c = q.runs.items[r].conds[k] orelse return;
    try q.watch.remove(c);
    q.runs.items[r].conds[k] = null;
}

fn unwatch(q: *Quests, r: u32) Error!void {
    for (0..q.runs.items[r].conds.len) |k| try q.unwatchStage(r, @intCast(k)); // safe: at most max_stages
}

// Everything kept beside the facts, built from them: each run, what is watched for it, and the active set.
fn rebuild(q: *Quests) Error!void {
    const ps = q.loaded.plan.quests;
    try q.runs.ensureTotalCapacity(q.gpa, ps.len);
    for (ps, 0..) |p, i| {
        const conds = try q.gpa.alloc(?react.CondId, p.stages.len);
        @memset(conds, null);
        q.runs.appendAssumeCapacity(.{ .quest = @intCast(i), .key = Value.no_ref, .status = .idle, .conds = conds, .used = !p.repeat }); // safe: at most max_quests
    }
    for (ps, 0..) |p, i| {
        const quest: QuestId = .fromRaw(@intCast(i)); // safe: at most max_quests
        if (!p.repeat) {
            try q.resumeRun(@intCast(i), .{ .quest = quest }); // safe: at most max_quests
            continue;
        }
        var key: u64 = 1;
        while (key <= q.started(quest)) : (key += 1) {
            if (q.status(.{ .quest = quest, .key = key }) != .active) continue;
            const r = try q.newRun(@intCast(i), key); // safe: at most max_quests
            try q.resumeRun(r, .{ .quest = quest, .key = key });
        }
    }
}

// A run as its facts left it: watched as its status says, and its keys in the active set.
fn resumeRun(q: *Quests, r: u32, i: Instance) Error!void {
    const s = q.status(i);
    q.runs.items[r].status = s;
    switch (s) {
        .active => {
            try q.repairCurrent(i);
            try q.watchAll(r);
            try q.activate(r, null);
        },
        .idle => if (q.plan(i.quest).starts_itself and (q.plan(i.quest).roles.len == 0 or q.bound(r))) try q.watchStarts(r),
        .done, .failed => {},
    }
}

// A save whose current stage a patch took away, or never had one: the last stage written that is reached.
fn repairCurrent(q: *Quests, i: Instance) Error!void {
    const p = q.plan(i.quest);
    if (p.current == block.none16 or q.current(i) != null) return;
    var k = p.stages.len;
    while (k > 0) {
        k -= 1;
        if (q.reached(i, .fromRaw(@intCast(k)))) return q.writeFact(p.current, i.key, .{ .one_of = @intCast(k) }); // safe: at most max_stages
    }
}

// ---------------------------------------------------------------- the builtins

fn answer(user: ?*anyopaque, _: *const story_.Story, index: u32, cx: run.Context) error{BuiltinFailed}!Value {
    const a: *const Answers = @ptrCast(@alignCast(user)); // safe: made by `builtins` from an *Answers
    const plan_ = a.loaded.plan;
    if (index >= plan_.calls.len) return error.BuiltinFailed;
    switch (plan_.calls[index]) {
        .none => return error.BuiltinFailed,
        .since => |x| {
            const p = plan_.quests[x.quest];
            if (!readIn(a.story, a.store, p.stages[x.stage].fact, cx.this).boolean) return .{ .int = 0 };
            const now = readIn(a.story, a.store, x.fact, cx.this).int;
            return .{ .int = now -| readIn(a.story, a.store, x.record, cx.this).int };
        },
        .before => |x| return .{ .boolean = readIn(a.story, a.store, x.latch, cx.this).boolean },
    }
}

// ---------------------------------------------------------------- a step

/// Evaluates what may have changed since the last step, reaching stages to a fixed point, and says what happened.
pub fn step(q: *Quests) Error!Step {
    _ = q.step_arena.reset(.retain_capacity);
    q.events.clearRetainingCapacity();
    try q.events.appendSlice(q.gpa, q.queued.items);
    q.queued.clearRetainingCapacity();
    var left = q.options.budget;
    var rounds: u32 = 0;
    while (true) : (rounds += 1) {
        if (rounds == max_rounds) return error.NoFixedPoint;
        q.watch.options.budget = left;
        const evaluated = try q.watch.step();
        q.evaluations += evaluated.len;
        if (left) |*l| l.* -= @min(l.*, @as(u32, @intCast(evaluated.len))); // safe: a budget's count
        if (!try q.round(evaluated)) break;
        if (left != null and left.? == 0) break;
    }
    return .{ .events = q.events.items };
}

/// The host's word that what a query reads changed: `family` is the stamp it declared, `keyed` the values of its
/// keyed parameters. The stages filed under it are evaluated at the next step.
pub fn bump(q: *Quests, family: []const u8, keyed: []const Value) Error!void {
    try q.watch.bump(family, keyed);
}

// One round: what the conditions evaluated hold, applied. False when nothing changed.
fn round(q: *Quests, evaluated: []const react.Evaluated) Error!bool {
    q.pending.clearRetainingCapacity();
    for (evaluated) |e| {
        const r = e.user >> 8;
        const k: u8 = @truncate(e.user); // safe: the low byte is the stage
        const x = q.runs.items[r];
        if (!x.used) continue;
        const st = q.loaded.plan.quests[x.quest].stages[k];
        const was = q.reached(q.instanceOf(r), .fromRaw(k));
        switch (x.status) {
            .idle => if (e.holds and st.after.len == 0) try q.pending.append(q.gpa, .{ .run = r, .stage = k, .reach = true }),
            .active => if (e.holds != was and (st.live or e.holds)) try q.pending.append(q.gpa, .{ .run = r, .stage = k, .reach = e.holds }),
            .done, .failed => {},
        }
    }
    if (q.pending.items.len == 0) return false;
    // the same order however the conditions were numbered: by run, then by stage
    std.mem.sort(Change, q.pending.items, {}, struct {
        fn less(_: void, a: Change, b: Change) bool {
            return a.run < b.run or (a.run == b.run and a.stage < b.stage);
        }
    }.less);
    var i: usize = 0;
    while (i < q.pending.items.len) {
        var j = i;
        while (j < q.pending.items.len and q.pending.items[j].run == q.pending.items[i].run) j += 1;
        try q.apply(q.pending.items[i].run, q.pending.items[i..j]);
        i = j;
    }
    return true;
}

// What changed for one run this round: started if it was idle, its stages reached and left, then the latches of
// what it reached, then its ending, and its keys.
fn apply(q: *Quests, r: u32, changes: []const Change) Error!void {
    const i = q.instanceOf(r);
    const p = q.plan(i.quest);
    var was: [block.max_keys * 2]u32 = undefined;
    const before = q.keysOf(r, &was);
    if (q.runs.items[r].status == .idle) {
        try q.writeFact(p.status, i.key, .{ .one_of = 0 });
        q.runs.items[r].status = .active;
        try q.events.append(q.gpa, .{ .instance = i, .what = .started });
        try q.unwatch(r);
        try q.watchAll(r);
    }
    var ending: ?u8 = null;
    for (changes) |c| {
        const st = p.stages[c.stage];
        if (c.reach and st.kind.ends()) {
            if (ending != null) return error.TwoEndings;
            ending = c.stage;
        }
        if (c.reach) try q.reach(r, c.stage) else try q.leave(r, c.stage);
    }
    for (changes) |c| if (c.reach) try q.latch(r, c.stage);
    if (ending) |k| try q.end(r, k);
    try q.activate(r, before);
    if (ending != null) try q.release(r);
}

fn reach(q: *Quests, r: u32, k: u8) Error!void {
    const i = q.instanceOf(r);
    const p = q.plan(i.quest);
    const st = p.stages[k];
    try q.writeFact(st.fact, i.key, .{ .boolean = true });
    if (p.current != block.none16) try q.writeFact(p.current, i.key, .{ .one_of = k });
    // what `since` counts from this stage is its fact's value now
    for (q.loaded.calls[i.quest.raw()]) |ci| switch (q.loaded.plan.calls[ci]) {
        .since => |x| if (x.stage == k) try q.writeFact(x.record, i.key, .{ .int = q.readFact(x.fact, i.key).int }),
        else => {},
    };
    if (!st.live) try q.unwatchStage(r, k);
    try q.events.append(q.gpa, .{ .instance = i, .what = .{ .reached = .{ .stage = .fromRaw(k), .effects = try q.effectsOf(r, st) } } });
}

fn leave(q: *Quests, r: u32, k: u8) Error!void {
    const i = q.instanceOf(r);
    const p = q.plan(i.quest);
    try q.writeFact(p.stages[k].fact, i.key, .{ .boolean = false });
    if (p.current != block.none16 and q.current(i) != null and q.current(i).?.raw() == k) {
        try q.writeFact(p.current, i.key, .{ .one_of = Value.none });
        try q.repairCurrent(i);
    }
    try q.events.append(q.gpa, .{ .instance = i, .what = .{ .left = .fromRaw(k) } });
}

// `before(a, b)` holds once `a` was reached while `b` was not: reached in the same round, neither came first.
fn latch(q: *Quests, r: u32, k: u8) Error!void {
    const i = q.instanceOf(r);
    for (q.loaded.calls[i.quest.raw()]) |ci| switch (q.loaded.plan.calls[ci]) {
        .before => |x| if (x.a == k and !q.reached(i, .fromRaw(x.b))) try q.writeFact(x.latch, i.key, .{ .boolean = true }),
        else => {},
    };
}

fn end(q: *Quests, r: u32, k: u8) Error!void {
    const i = q.instanceOf(r);
    const p = q.plan(i.quest);
    const failed = p.stages[k].kind == .fails;
    try q.writeFact(p.status, i.key, .{ .one_of = if (failed) 2 else 1 });
    q.runs.items[r].status = if (failed) .failed else .done;
    try q.unwatch(r);
    try q.events.append(q.gpa, .{ .instance = i, .what = .{ .ended = .{ .stage = .fromRaw(k), .failed = failed } } });
}

// A run ended is let go: a repeat quest's instance is only its facts from now on.
fn release(q: *Quests, r: u32) Error!void {
    const x = q.runs.items[r];
    if (!q.loaded.plan.quests[x.quest].repeat) return;
    q.gpa.free(x.conds);
    q.runs.items[r] = .{ .quest = x.quest, .key = Value.no_ref, .status = .idle, .conds = &.{}, .used = false };
    try q.free.append(q.gpa, r);
}

// What reaching a stage does: the effects of its body and of its lines, in order, worked out for the instance.
fn effectsOf(q: *Quests, r: u32, st: block.Stage) Error![]const facts.Effect {
    const a = q.step_arena.allocator();
    var out: std.ArrayList(facts.Effect) = .empty;
    const cx = try q.context(a, r, st);
    var at = q.story.section(.fromRaw(st.section)).entry;
    var walked: usize = 0;
    while (at) |n| : (walked += 1) {
        if (walked == q.story.len(.nodes)) break;
        const node = q.story.node(n);
        const list: story_.Range, const next = switch (node.step) {
            .line => |l| .{ l.effects, l.next },
            .effects => |e| .{ e.effects, e.next },
            else => break,
        };
        for (0..list.len) |k| try out.append(a, try run.eval.effect(cx, q.story.effect(list.start + @as(u32, @intCast(k))))); // safe: below a u32 length
        at = next;
    }
    return out.items;
}

fn context(q: *Quests, a: std.mem.Allocator, r: u32, st: block.Stage) Error!run.eval.Context {
    const x = q.runs.items[r];
    return .{
        .story = q.story,
        .store = q.store,
        .host = q.host,
        .call = .{ .flow = run.no_flow, .owners = q.owners, .this = x.key },
        .arena = a,
        .builtins = q.builtins(),
        .roles = try q.rolesFor(a, q.instanceOf(r), st),
    };
}

// ---------------------------------------------------------------- the active set

// The keys a run keeps active now: its current stage's `active`, and the `keeps` of every stage it reached.
fn keysOf(q: *const Quests, r: u32, out: []u32) []u32 {
    const i = q.instanceOf(r);
    if (q.status(i) != .active) return out[0..0];
    const p = q.plan(i.quest);
    var n: usize = 0;
    if (q.current(i)) |c| for (p.stages[c.raw()].active) |t| {
        if (n < out.len) out[n] = t;
        n += 1;
    };
    for (p.stages, 0..) |st, k| if (st.keeps.len > 0 and q.reached(i, .fromRaw(@intCast(k)))) for (st.keeps) |t| { // safe: at most max_stages
        if (n < out.len) out[n] = t;
        n += 1;
    };
    return out[0..@min(n, out.len)];
}

// The run's keys now against what they were (none where `before` is null), the active set and the events told.
fn activate(q: *Quests, r: u32, before: ?[]const u32) Error!void {
    var buf: [block.max_keys * 2]u32 = undefined;
    const now = q.keysOf(r, &buf);
    const i = q.instanceOf(r);
    const old = before orelse &.{};
    for (old) |t| if (std.mem.findScalar(u32, now, t) == null) {
        if (try q.active.take(q.gpa, i, t)) |key| try q.events.append(q.gpa, .{ .instance = i, .what = .{ .deactivated = key } });
    };
    for (now) |t| if (std.mem.findScalar(u32, old, t) == null) {
        const key: Active.Key = .{ .handle = q.host.refs[t], .name = q.story.thing(t).id };
        if (try q.active.give(q.gpa, i, t, key)) if (before != null) try q.events.append(q.gpa, .{ .instance = i, .what = .{ .activated = key } });
    };
}

// ---------------------------------------------------------------- the journal

/// The instance's journal: each stage it reached and each objective open, in the order written, in `out`.
pub fn journal(q: *const Quests, i: Instance, out: []Entry) []Entry {
    const p = q.plan(i.quest);
    const active = q.status(i) == .active;
    var n: usize = 0;
    for (p.stages, 0..) |st, k| {
        if (n == out.len) break;
        const id: StageId = .fromRaw(@intCast(k)); // safe: at most max_stages
        const done = q.reached(i, id);
        const open = active and !done and st.kind == .objective and for (st.after) |b| {
            if (!q.reached(i, .fromRaw(b))) break false;
        } else true;
        if (!done and !open) continue;
        out[n] = .{ .stage = id, .kind = st.kind, .open = open };
        n += 1;
    }
    return out[0..n];
}

/// A stage's journal lines, the texts of its body's lines in order, in `out`.
pub fn lines(q: *const Quests, quest: QuestId, stage: StageId, out: []story_.TextId) []story_.TextId {
    const st = q.plan(quest).stages[stage.raw()];
    var n: usize = 0;
    var at = q.story.section(.fromRaw(st.section)).entry;
    var walked: usize = 0;
    while (at) |id| : (walked += 1) {
        if (n == out.len or walked == q.story.len(.nodes)) break;
        at = switch (q.story.node(id).step) {
            .line => |l| blk: {
                out[n] = l.text;
                n += 1;
                break :blk l.next;
            },
            .effects => |e| e.next,
            else => null,
        };
    }
    return out[0..n];
}

/// A journal line's words for the instance, its roles and its own facts filled in, valid until the next `say`.
pub fn say(q: *Quests, words: *const story_.Strings, i: Instance, stage: StageId, text: story_.TextId, language: run.Language) (Error || run.text.Error)![]const u8 {
    _ = q.say_arena.reset(.retain_capacity);
    const a = q.say_arena.allocator();
    const st = q.plan(i.quest).stages[stage.raw()];
    const cx: run.eval.Context = .{
        .story = q.story,
        .store = q.store,
        .host = q.host,
        .call = .{ .flow = run.no_flow, .owners = q.owners, .this = i.key },
        .arena = a,
        .builtins = q.builtins(),
        .language = language,
        .roles = try q.rolesFor(a, i, st),
    };
    return run.text.render(cx, words, text);
}

const testing = @import("testing.zig");

test "a quest that starts itself is reached as its facts change, and ends at its outcome" {
    const gpa = std.testing.allocator;
    var built = try testing.build(gpa, null);
    defer built.deinit(gpa);
    const s: story_.Story = try .init(built.graph, .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var memory: facts.Memory = try .init(gpa, try s.schema(arena.allocator()));
    defer memory.deinit();
    const owners: [facts.max_scopes]u64 = @splat(0);
    var q: Quests = try .init(gpa, &s, memory.store(), &run.Host.none, &owners, .{});
    defer q.deinit();
    const i: Instance = .{ .quest = q.questNamed("q").? };
    try std.testing.expectEqual(@as(usize, 0), (try q.step()).events.len);
    try memory.set(s.factNamed("met").?, .{ .boolean = true });
    const first = try q.step();
    try std.testing.expect(first.events[0].what == .started);
    try std.testing.expectEqual(q.stageNamed(i.quest, "noticed").?, q.current(i).?);
    // what a stage does is emitted, never applied
    try memory.set(s.factNamed("told").?, .{ .boolean = true });
    const last = try q.step();
    try std.testing.expectEqual(Status.done, q.status(i));
    try std.testing.expectEqual(@as(usize, 1), last.events[0].what.reached.effects.len);
    try std.testing.expectEqual(@as(i64, 0), memory.get(s.factNamed("gold").?).int);
    var entries: [4]Entry = undefined;
    try std.testing.expectEqual(@as(usize, 2), q.journal(i, &entries).len);
    // a quest that ran once is not started again
    try std.testing.expectError(error.AlreadyStarted, q.start(i.quest, &.{}));
    try std.testing.expectError(error.WrongRoles, q.start(i.quest, &.{.{ .int = 1 }}));
}

test "the quests are what the facts say, however they came to say it" {
    const gpa = std.testing.allocator;
    var built = try testing.build(gpa, null);
    defer built.deinit(gpa);
    const s: story_.Story = try .init(built.graph, .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var memory: facts.Memory = try .init(gpa, try s.schema(arena.allocator()));
    defer memory.deinit();
    const owners: [facts.max_scopes]u64 = @splat(0);
    // a save in which the quest was started and noticed: nothing is said of it, and it goes on from there
    try memory.set(s.factNamed("q.@status").?, .{ .one_of = 0 });
    try memory.set(s.factNamed("q.noticed").?, .{ .boolean = true });
    var q: Quests = try .init(gpa, &s, memory.store(), &run.Host.none, &owners, .{});
    defer q.deinit();
    const i: Instance = .{ .quest = q.questNamed("q").? };
    try std.testing.expectEqual(Status.active, q.status(i));
    try std.testing.expectEqual(q.stageNamed(i.quest, "noticed").?, q.current(i).?);
    _ = try q.step();
    try memory.set(s.factNamed("told").?, .{ .boolean = true });
    _ = try q.step();
    try std.testing.expectEqual(Status.done, q.status(i));
}
