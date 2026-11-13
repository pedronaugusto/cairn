//! cairn's block in a compiled story: the story's quests as cairn's compile
//! pass wrote them beside riverrun's graph. Each quest's section, its roles,
//! the facts cairn keeps for it, and its stages: each stage's condition (a
//! range of the story's terms), its kind, what it comes after and the keys
//! it activates; then what each of cairn's builtin calls reads, and the
//! dependency index, the stages that read each fact. Facts, sections and
//! things are the compiled story's ids; names stay the story's.
//!
//! Little-endian, in this order: the quests, the calls, the readers. Each
//! list is a count and its records. A reader never trusts the bytes: every
//! count is bounded, every tag known, every index within its list, and the
//! block must end where its last record does. What the block names of the
//! story is checked against the story when it is loaded.

const std = @import("std");
const aegis = @import("aegis");

/// The block's name in a compiled story.
pub const name = "cairn";
/// Bumped when a record changes; a reader refuses another.
pub const version: u32 = 1;

/// A fact that is not there.
pub const none16: u16 = 0xFFFF;

/// The most stages a quest has, its own and those it inherits.
pub const max_stages = 256;
/// The most roles a quest is given.
pub const max_roles = 16;
/// The most quests a story holds.
pub const max_quests = 1 << 20;
/// The most keys one stage activates.
pub const max_keys = 64;
/// The most builtin calls a story makes.
pub const max_calls = 1 << 20;
/// The most stages that read facts, counted once per fact read.
pub const max_reads = 1 << 24;

pub const Error = error{
    /// The bytes are not a block this reader wrote: cut short, too long, a count past its bound, an unknown tag.
    Malformed,
    OutOfMemory,
};

pub const Kind = enum(u8) {
    /// A step of the way, recorded in the journal.
    stage = 0,
    /// Something the player is trying to do: open once what it comes after is reached.
    objective = 1,
    /// An ending: the quest is done.
    outcome = 2,
    /// An ending: the quest failed.
    fails = 3,

    pub fn ends(k: Kind) bool {
        return k == .outcome or k == .fails;
    }
};

pub const Plan = struct {
    quests: []const Quest,
    /// By the story's builtin call: what it reads, where it is cairn's.
    calls: []const Call,
    /// For each fact, the stages whose conditions read it.
    readers: Readers,
};

pub const Quest = struct {
    /// The `(quest)` section; its name is the quest's.
    section: u32,
    /// Runs as many instances, each kept per a thing of the quest's own kind.
    repeat: bool,
    /// Starts when a stage with no `after` is reached; false for `# start host` and for a repeat quest.
    starts_itself: bool,
    /// The facts cairn keeps for it: its status, its current stage, and for a repeat quest how many instances
    /// it has started.
    status: u16,
    current: u16,
    count: u16 = none16,
    /// Its `(role)` facts, in the order written: the roles `start` takes.
    roles: []const u16,
    /// Its own stages in the order written, then those it inherits.
    stages: []const Stage,
};

pub const Stage = struct {
    /// The part's section: its journal lines and its effects.
    section: u32,
    /// The fact true once it is reached.
    fact: u16,
    /// Its condition, in the story's terms.
    when: Range,
    kind: Kind,
    /// Follows its condition, where another stage stays reached.
    live: bool = false,
    /// An objective the quest can end without.
    optional: bool = false,
    /// The stages it comes after, by their place in the quest.
    after: []const u8 = &.{},
    /// The things its keys are, which stay active while it is the quest's current stage, and from it until the
    /// quest ends.
    active: []const u32 = &.{},
    keeps: []const u32 = &.{},
    /// The roles its terms read, each by the fact they read it as and the quest's role it is: a quest's own stage
    /// reads the quest's, one inherited from shared rules the rules' own.
    roles: []const RoleRead = &.{},
};

pub const Range = struct { start: u32, len: u32 };

pub const RoleRead = struct { fact: u16, role: u8 };

pub const Call = union(enum) {
    /// Another package's, or none.
    none,
    /// `since(stage, fact)`: how far `fact` moved since the stage was reached, which `record` keeps.
    since: struct { quest: u32, stage: u8, fact: u16, record: u16 },
    /// `before(a, b)`: whether `a` was reached while `b` was not, which `latch` keeps.
    before: struct { quest: u32, a: u8, b: u8, latch: u16 },
};

/// A compressed sparse index: the stages that read fact `f` are `stages[starts[f]..starts[f + 1]]`.
pub const Readers = struct {
    starts: []const u32,
    stages: []const StageRef,

    pub fn of(r: Readers, fact: u16) []const StageRef {
        if (fact + 1 >= r.starts.len) return &.{};
        return r.stages[r.starts[fact]..r.starts[fact + 1]];
    }
};

/// A stage, by its quest and its place there.
pub const StageRef = packed struct(u32) { stage: u8, quest: u24 };

// ---------------------------------------------------------------- writing

/// The block's bytes, on `gpa`, owned by the caller.
pub fn write(gpa: std.mem.Allocator, p: Plan) error{OutOfMemory}![]u8 {
    aegis.assert.invariant(p.quests.len <= max_quests, "a plan holds at most max_quests quests, as the compiler builds it");
    aegis.assert.invariant(p.calls.len <= max_calls, "a plan holds at most max_calls calls, as the compiler builds it");
    var w: Writer = .{ .gpa = gpa };
    errdefer w.out.deinit(gpa);
    try w.int(u32, @intCast(p.quests.len)); // safe: asserted above
    for (p.quests) |q| try w.quest(q);
    try w.int(u32, @intCast(p.calls.len)); // safe: asserted above
    for (p.calls) |c| try w.call(c);
    aegis.assert.invariant(p.readers.stages.len <= max_reads, "a plan holds at most max_reads stage readers, as the compiler builds it");
    try w.int(u32, @intCast(p.readers.starts.len)); // safe: one more than the story's facts
    for (p.readers.starts) |s| try w.int(u32, s);
    try w.int(u32, @intCast(p.readers.stages.len)); // safe: asserted above
    for (p.readers.stages) |s| try w.int(u32, @bitCast(s));
    return w.out.toOwnedSlice(gpa);
}

const Writer = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn int(w: *Writer, comptime T: type, v: T) error{OutOfMemory}!void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        try w.out.appendSlice(w.gpa, &buf);
    }

    fn quest(w: *Writer, q: Quest) error{OutOfMemory}!void {
        aegis.assert.invariant(q.roles.len <= max_roles, "a quest holds at most max_roles roles");
        aegis.assert.invariant(q.stages.len <= max_stages, "a quest holds at most max_stages stages");
        try w.int(u32, q.section);
        try w.int(u8, @as(u8, @intFromBool(q.repeat)) | (@as(u8, @intFromBool(q.starts_itself)) << 1));
        try w.int(u16, q.status);
        try w.int(u16, q.current);
        try w.int(u16, q.count);
        try w.int(u8, @intCast(q.roles.len)); // safe: asserted above
        for (q.roles) |r| try w.int(u16, r);
        try w.int(u16, @intCast(q.stages.len)); // safe: asserted above
        for (q.stages) |s| try w.stage(s);
    }

    fn stage(w: *Writer, s: Stage) error{OutOfMemory}!void {
        try w.int(u32, s.section);
        try w.int(u16, s.fact);
        try w.int(u32, s.when.start);
        try w.int(u32, s.when.len);
        try w.int(u8, @backingInt(s.kind));
        try w.int(u8, @as(u8, @intFromBool(s.live)) | (@as(u8, @intFromBool(s.optional)) << 1));
        try w.list(u8, s.after);
        try w.list(u32, s.active);
        try w.list(u32, s.keeps);
        aegis.assert.invariant(s.roles.len <= max_roles, "a stage names at most max_roles roles");
        try w.int(u8, @intCast(s.roles.len)); // safe: asserted above
        for (s.roles) |r| {
            try w.int(u16, r.fact);
            try w.int(u8, r.role);
        }
    }

    fn list(w: *Writer, comptime T: type, items: []const T) error{OutOfMemory}!void {
        aegis.assert.invariant(items.len <= std.math.maxInt(u8), "a list fits its u8 length");
        try w.int(u8, @intCast(items.len)); // safe: asserted above
        for (items) |v| try w.int(T, v);
    }

    fn call(w: *Writer, c: Call) error{OutOfMemory}!void {
        switch (c) {
            .none => try w.int(u8, 0),
            .since => |s| {
                try w.int(u8, 1);
                try w.int(u32, s.quest);
                try w.int(u8, s.stage);
                try w.int(u16, s.fact);
                try w.int(u16, s.record);
            },
            .before => |b| {
                try w.int(u8, 2);
                try w.int(u32, b.quest);
                try w.int(u8, b.a);
                try w.int(u8, b.b);
                try w.int(u16, b.latch);
            },
        }
    }
};

// ---------------------------------------------------------------- reading

/// The plan in `bytes`, its lists on `arena`. Every index within the block is checked; what it names of the
/// story is the loader's to check against the story.
pub fn read(arena: std.mem.Allocator, bytes: []const u8) Error!Plan {
    var r: Reader = .{ .bytes = bytes };
    const quests = try arena.alloc(Quest, try r.count(u32, max_quests, quest_bytes));
    for (quests) |*q| q.* = try r.quest(arena);
    const calls = try arena.alloc(Call, try r.count(u32, max_calls, 1));
    for (calls) |*c| c.* = try r.call(quests);
    const starts = try arena.alloc(u32, try r.count(u32, std.math.maxInt(u16) + 2, 4));
    for (starts) |*s| s.* = try r.int(u32);
    const stages = try arena.alloc(StageRef, try r.count(u32, max_reads, 4));
    for (stages) |*s| {
        s.* = @bitCast(try r.int(u32));
        if (s.quest >= quests.len or s.stage >= quests[s.quest].stages.len) return error.Malformed;
    }
    // the starts climb to the entries' end
    var at: u32 = 0;
    for (starts) |s| {
        if (s < at or s > stages.len) return error.Malformed;
        at = s;
    }
    if (starts.len > 0 and at != stages.len) return error.Malformed;
    if (r.i != bytes.len) return error.Malformed;
    return .{ .quests = quests, .calls = calls, .readers = .{ .starts = starts, .stages = stages } };
}

// The fewest bytes a quest's record and a stage's take, so a count no bytes could hold is refused before anything
// is made for it.
const quest_bytes = 14;
const stage_bytes = 20;

const Reader = struct {
    bytes: []const u8,
    i: usize = 0,

    fn int(r: *Reader, comptime T: type) Error!T {
        if (r.bytes.len - r.i < @sizeOf(T)) return error.Malformed;
        const v = std.mem.readInt(T, r.bytes[r.i..][0..@sizeOf(T)], .little);
        r.i += @sizeOf(T);
        return v;
    }

    // A count of records of at least `each` bytes, no more than `bound` and than the bytes left could hold.
    fn count(r: *Reader, comptime T: type, bound: usize, each: usize) Error!usize {
        const n = try r.int(T);
        if (n > bound or n * each > r.bytes.len - r.i) return error.Malformed;
        return n;
    }

    fn quest(r: *Reader, arena: std.mem.Allocator) Error!Quest {
        const section = try r.int(u32);
        const flags = try r.int(u8);
        if (flags > 0b11) return error.Malformed;
        var q: Quest = .{ .section = section, .repeat = flags & 1 != 0, .starts_itself = flags & 2 != 0, .status = try r.int(u16), .current = try r.int(u16), .count = try r.int(u16), .roles = &.{}, .stages = &.{} };
        const roles = try arena.alloc(u16, try r.count(u8, max_roles, 2));
        for (roles) |*f| f.* = try r.int(u16);
        const stages = try arena.alloc(Stage, try r.count(u16, max_stages, stage_bytes));
        for (stages) |*s| s.* = try r.stage(arena, roles.len);
        for (stages) |s| for (s.after) |a| if (a >= stages.len) return error.Malformed;
        q.roles = roles;
        q.stages = stages;
        return q;
    }

    fn stage(r: *Reader, arena: std.mem.Allocator, roles: usize) Error!Stage {
        var s: Stage = .{ .section = try r.int(u32), .fact = try r.int(u16), .when = .{ .start = try r.int(u32), .len = try r.int(u32) }, .kind = .stage };
        s.kind = std.enums.fromInt(Kind, try r.int(u8)) orelse return error.Malformed;
        const flags = try r.int(u8);
        if (flags > 0b11) return error.Malformed;
        s.live = flags & 1 != 0;
        s.optional = flags & 2 != 0;
        s.after = try r.list(arena, u8, std.math.maxInt(u8));
        s.active = try r.list(arena, u32, max_keys);
        s.keeps = try r.list(arena, u32, max_keys);
        const reads = try arena.alloc(RoleRead, try r.count(u8, max_roles, 3));
        for (reads) |*x| {
            x.* = .{ .fact = try r.int(u16), .role = try r.int(u8) };
            if (x.role >= roles) return error.Malformed;
        }
        s.roles = reads;
        return s;
    }

    fn list(r: *Reader, arena: std.mem.Allocator, comptime T: type, bound: usize) Error![]const T {
        const out = try arena.alloc(T, try r.count(u8, bound, @sizeOf(T)));
        for (out) |*v| v.* = try r.int(T);
        return out;
    }

    fn call(r: *Reader, quests: []const Quest) Error!Call {
        const c: Call = switch (try r.int(u8)) {
            0 => .none,
            1 => .{ .since = .{ .quest = try r.int(u32), .stage = try r.int(u8), .fact = try r.int(u16), .record = try r.int(u16) } },
            2 => .{ .before = .{ .quest = try r.int(u32), .a = try r.int(u8), .b = try r.int(u8), .latch = try r.int(u16) } },
            else => return error.Malformed,
        };
        switch (c) {
            .none => {},
            .since => |s| if (s.quest >= quests.len or s.stage >= quests[s.quest].stages.len) return error.Malformed,
            .before => |b| if (b.quest >= quests.len or b.a >= quests[b.quest].stages.len or b.b >= quests[b.quest].stages.len) return error.Malformed,
        }
        return c;
    }
};

test "a plan reads back as it was written" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const stages = [_]Stage{
        .{ .section = 4, .fact = 10, .when = .{ .start = 3, .len = 1 }, .kind = .stage },
        .{ .section = 5, .fact = 11, .when = .{ .start = 4, .len = 3 }, .kind = .objective, .optional = true, .after = &.{0}, .active = &.{ 2, 7 }, .roles = &.{.{ .fact = 9, .role = 0 }} },
        .{ .section = 6, .fact = 12, .when = .{ .start = 7, .len = 2 }, .kind = .outcome, .after = &.{1}, .keeps = &.{1} },
    };
    const plan: Plan = .{
        .quests = &.{.{ .section = 3, .repeat = true, .starts_itself = false, .status = 13, .current = 14, .count = 15, .roles = &.{9}, .stages = &stages }},
        .calls = &.{ .none, .{ .since = .{ .quest = 0, .stage = 0, .fact = 2, .record = 16 } }, .{ .before = .{ .quest = 0, .a = 1, .b = 2, .latch = 17 } } },
        .readers = .{ .starts = &.{ 0, 0, 1, 2 }, .stages = &.{ .{ .quest = 0, .stage = 1 }, .{ .quest = 0, .stage = 2 } } },
    };
    const bytes = try write(std.testing.allocator, plan);
    defer std.testing.allocator.free(bytes);
    const back = try read(arena.allocator(), bytes);
    const q = back.quests[0];
    try std.testing.expect(q.repeat and !q.starts_itself);
    try std.testing.expectEqual(@as(u16, 15), q.count);
    try std.testing.expectEqual(Kind.objective, q.stages[1].kind);
    try std.testing.expect(q.stages[1].optional and !q.stages[1].live);
    try std.testing.expectEqualSlices(u32, &.{ 2, 7 }, q.stages[1].active);
    try std.testing.expectEqual(@as(u8, 0), q.stages[1].roles[0].role);
    try std.testing.expectEqual(@as(u16, 17), back.calls[2].before.latch);
    try std.testing.expectEqual(@as(usize, 1), back.readers.of(2).len);
    try std.testing.expectEqual(@as(u8, 2), back.readers.of(2)[0].stage);
    try std.testing.expectEqual(@as(usize, 0), back.readers.of(9).len);
    // cut short anywhere, or with a byte too many, it is refused
    for (0..bytes.len) |n| try std.testing.expectError(error.Malformed, read(arena.allocator(), bytes[0..n]));
    const longer = try std.mem.concat(std.testing.allocator, u8, &.{ bytes, &.{0} });
    defer std.testing.allocator.free(longer);
    try std.testing.expectError(error.Malformed, read(arena.allocator(), longer));
}

test "any bytes are read or refused, never crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [1024]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            _ = read(arena.allocator(), bytes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.Malformed => {},
            };
        }
    }.one, .{});
}
