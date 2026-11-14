//! A large game's quests, at the design's napkin scale: `bay bench`, or
//! `zig-out/bench/quests [--smoke] [--row PREFIX]` by hand. Two thousand
//! quests of twenty stages, forty thousand conditions of about nine terms,
//! each over two of 1,500 facts and the count of one of 10,000 item kinds the
//! game keeps, every quest started. A unit is one step: after a choice that
//! changes five facts, after a pickup that bumps one item's stamp, and after
//! nothing; and, timed once, the story's compile and its load. The sizes and
//! what each step evaluated go to stderr. CI compiles this and times
//! nothing; `--smoke` runs every row once on twenty quests.

const std = @import("std");
const riverrun = @import("riverrun");
const compiler = @import("riverrun-compiler");
const cairn = @import("cairn");
const cairn_compiler = @import("cairn-compiler");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const facts = riverrun.facts;
const WorkloadError = cairn.Error || error{ StoryRefused, Story, BuildFailed };

const Vocabulary = struct {
    pub const options: compiler.check.Options = .{};
    pub const packages: []const compiler.Package = &.{cairn_compiler.package};
};
const joined = compiler.join(Vocabulary);

const Size = struct { quests: usize, stages: usize, facts: usize, items: usize };
const full: Size = .{ .quests = 2000, .stages = 20, .facts = 1500, .items = 10_000 };
const small: Size = .{ .quests = 20, .stages = 20, .facts = 60, .items = 100 };

// The story's text: each stage reads the stage before it, two of the facts and one item's count, which stays 0,
// so every condition the steps wake is evaluated and none is reached.
fn generate(gpa: std.mem.Allocator, size: Size) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("facts (world):\n");
    for (0..size.facts) |f| try w.print("  f{d}: bool   (game)\n", .{f});
    try w.writeAll("extern:\n  count(kind: ref of item_kind) -> int   (reads stock(kind))\n");
    var seed: u64 = 1;
    for (0..size.quests) |q| {
        try w.print("== q{d} (quest)\n  [start host]\n", .{q});
        for (0..size.stages) |k| {
            const a = next(&seed) % size.facts;
            const b = next(&seed) % size.facts;
            const item = next(&seed) % size.items;
            const kind = if (k + 1 == size.stages) "outcome" else "stage";
            if (k == 0) {
                try w.print("= s0   when {{ f{d} and f{d} and count(item_{d}) >= 3 }}\n  [stage]\n", .{ a, b, item });
            } else try w.print("= s{d}   when {{ s{d} and f{d} and f{d} and count(item_{d}) >= 3 }}\n  [{s}] [after s{d}]\n", .{ k, k - 1, a, b, item, kind, k - 1 });
        }
    }
    return out.toOwnedSlice();
}

fn next(seed: *u64) u64 {
    seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
    return seed.* >> 33;
}

const Context = struct {
    gpa: std.mem.Allocator,
    size: Size,
    text: []u8 = &.{},
    compiled: ?compiler.compile.Compiled = null,
    story: riverrun.story.Story = undefined,
    arena: std.heap.ArenaAllocator,
    memory: ?facts.Memory = null,
    host: riverrun.run.Host = .none,
    owners: [facts.max_scopes]u64 = @splat(0),
    quests: ?cairn.Quests = null,
    seed: u64 = 7,
    stock: Stock = .{},
    /// The world's facts a choice changes, `f0` on.
    world: []facts.FactId = &.{},

    const Stock = struct {
        fn count(_: *Stock, _: riverrun.run.Context, _: u64) i64 {
            return 0;
        }
    };

    fn compile(c: *Context) WorkloadError!void {
        if (c.compiled) |*old| old.deinit(c.gpa);
        c.compiled = null;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        var diags: compiler.syntax.Diagnostics = .{};
        defer diags.deinit(c.gpa);
        const tree = try arena.allocator().create(compiler.syntax.ast.File);
        tree.* = try compiler.syntax.parse(arena.allocator(), c.gpa, &diags, 0, "quests.river", c.text);
        var checked = try compiler.check.run(c.gpa, &diags, tree[0..1], joined.options);
        defer checked.deinit();
        if (diags.errors() > 0) return error.StoryRefused;
        c.compiled = compiler.compile.run(c.gpa, &diags, &checked, .{ .passes = joined.passes }) catch return error.BuildFailed;
    }

    fn load(c: *Context) WorkloadError!void {
        c.release();
        c.story = riverrun.story.Story.init(c.compiled.?.graph, .{}) catch return error.Story;
        c.memory = facts.Memory.init(c.gpa, c.story.schema(c.arena.allocator()) catch return error.OutOfMemory) catch return error.Story;
        c.host = riverrun.run.Host.bind(c.gpa, &c.story, &c.stock, .{ .count = Stock.count }, null) catch return error.Story;
        const Things = struct {
            fn resolve(_: ?*anyopaque, _: []const u8, id: []const u8) ?u64 {
                return 1 + (std.fmt.parseInt(u64, id["item_".len..], 10) catch 0);
            }
        };
        c.host.resolveStory(c.gpa, &c.story, .{ .user = null, .resolve = Things.resolve }, null) catch return error.Story;
        c.quests = try cairn.Quests.init(c.gpa, &c.story, c.memory.?.store(), &c.host, &c.owners, .{});
        if (c.world.len == 0) c.world = try c.worldFacts();
        const q = &c.quests.?;
        for (0..q.quests().len) |i| _ = try q.start(.fromRaw(@intCast(i)), &.{}); // safe: below the quests' count
        _ = try q.step();
    }

    fn worldFacts(c: *Context) error{OutOfMemory}![]facts.FactId {
        const out = try c.arena.allocator().alloc(facts.FactId, c.size.facts);
        for (0..c.story.len(.facts)) |i| {
            const name = c.story.fact(.fromRaw(@intCast(i))).name; // safe: below the facts' count
            if (name.len < 2 or name[0] != 'f') continue;
            // a fact named otherwise is not one the bench made
            const n = (std.fmt.parseInt(usize, name[1..], 10) catch null) orelse continue;
            if (n < out.len) out[n] = .fromRaw(@intCast(i)); // safe: below the facts' count
        }
        return out;
    }

    fn release(c: *Context) void {
        if (c.quests) |*q| q.deinit();
        c.quests = null;
        c.host.deinit();
        c.host = .none;
        if (c.memory) |*m| m.deinit();
        c.memory = null;
    }

    fn deinit(c: *Context) void {
        c.release();
        if (c.compiled) |*k| k.deinit(c.gpa);
        c.gpa.free(c.text);
        c.arena.deinit();
    }

    fn compileRow(c: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| try c.compile();
    }

    fn loadRow(c: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| try c.load();
    }

    // A dialogue choice: five facts change, then a step.
    fn choice(c: *Context, units: u64) WorkloadError!void {
        const m = &c.memory.?;
        for (0..units) |_| {
            for (0..5) |_| {
                const f = c.world[next(&c.seed) % c.world.len];
                try m.set(f, .{ .boolean = !m.get(f).boolean });
            }
            std.mem.doNotOptimizeAway((try c.quests.?.step()).events.len);
        }
    }

    // A pickup: one item's stamp bumped, then a step.
    fn pickup(c: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| {
            const item = 1 + next(&c.seed) % c.size.items;
            try c.quests.?.bump("stock", &.{.{ .ref = item }});
            std.mem.doNotOptimizeAway((try c.quests.?.step()).events.len);
        }
    }

    fn idle(c: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| std.mem.doNotOptimizeAway((try c.quests.?.step()).events.len);
    }
};

const Row = shakedown.bench.Row(Context, WorkloadError);

const rows = [_]Row{
    .{ .name = "compile the story", .unit = "story", .grow = false, .run = Context.compileRow },
    .{ .name = "load and start every quest", .unit = "story", .grow = false, .run = Context.loadRow },
    .{ .name = "step after a choice of five facts", .unit = "step", .run = Context.choice },
    .{ .name = "step after a pickup", .unit = "step", .run = Context.pickup },
    .{ .name = "step after nothing", .unit = "step", .run = Context.idle },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options: shakedown.bench.Options = try .fromArguments(args[1..]);
    var c: Context = .{ .gpa = init.gpa, .size = if (options.smoke) small else full, .arena = .init(init.gpa) };
    defer c.deinit();
    c.text = try generate(init.gpa, c.size);
    try c.compile();
    try c.load();
    var said: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &said);
    // a smoke run reports into nothing: under the gate a passing run says nothing
    var nothing: std.Io.Writer.Discarding = .init(&.{});
    const out = if (options.smoke) &nothing.writer else &stderr.interface;
    try report(&c, out);
    try instances(init.gpa, init.io, out, if (options.smoke) 100 else 100_000);
    try out.flush();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try shakedown.bench.run(WorkloadError, init.gpa, init.io, &writer.interface, &c, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, options);
    try writer.interface.flush();
}

// What the story and its steps came to: sizes, and conditions evaluated a step.
fn report(c: *Context, w: *std.Io.Writer) (WorkloadError || std.Io.Writer.Error)!void {
    const s = &c.story;
    const block = s.block(cairn.block.name).?;
    try w.print("quests {d} · stages {d} · facts {d} · terms {d} · graph {d} bytes · cairn's block {d} bytes · source {d} bytes\n", .{ c.size.quests, c.size.quests * c.size.stages, s.len(.facts), s.len(.terms), c.compiled.?.graph.len, block.bytes.len, c.text.len });
    // where the graph's bytes go, its largest tables first
    const format = riverrun.story.format;
    var tables: [format.table_count]struct { name: []const u8, bytes: usize } = undefined;
    inline for (@typeInfo(format.Table).@"enum".field_names, 0..) |name, i| {
        tables[i] = .{ .name = name, .bytes = @as(usize, s.len(@field(format.Table, name))) * @sizeOf(format.Record(@field(format.Table, name))) };
    }
    std.mem.sort(@TypeOf(tables[0]), &tables, {}, struct {
        fn more(_: void, a: @TypeOf(tables[0]), b: @TypeOf(tables[0])) bool {
            return a.bytes > b.bytes;
        }
    }.more);
    try w.writeAll("the graph's largest tables:");
    for (tables[0..6]) |t| try w.print(" {s} {d} KB ·", .{ t.name, t.bytes / 1024 });
    try w.writeAll("\n");
    const q = &c.quests.?;
    const before = q.evaluations;
    try c.choice(100);
    const choices = q.evaluations - before;
    try c.pickup(100);
    const pickups = q.evaluations - before - choices;
    try w.print("evaluated a step: {d:.1} after a choice of five facts, {d:.1} after a pickup\n", .{ @as(f64, @floatFromInt(choices)) / 100, @as(f64, @floatFromInt(pickups)) / 100 });
}

// A board of one repeat quest, `n` instances started and then all ended: how long each step takes, and what the
// facts and cairn hold while they run and once they ended, through an allocator that counts.
fn instances(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, n: usize) !void {
    var counting: Counting = .{ .child = gpa };
    const a = counting.allocator();
    var c: Context = .{ .gpa = a, .size = small, .arena = .init(a) };
    defer c.deinit();
    c.text = try a.dupe(u8,
        \\facts (world):
        \\  closed: bool   (game)
        \\  dead(person): bool   (game)
        \\== bounty (quest)
        \\  [repeat] [scope world]
        \\facts (world):
        \\  target: ref of person   (role)
        \\= posted    when { true }
        \\  [stage]
        \\= closed_   when { closed }
        \\  [outcome] [after posted]
        \\= claimed   when { dead(target) and not closed }
        \\  [outcome] [after posted]
    );
    try c.compile();
    c.story = riverrun.story.Story.init(c.compiled.?.graph, .{}) catch return error.Story;
    c.memory = try facts.Memory.init(a, try c.story.schema(c.arena.allocator()));
    c.quests = try cairn.Quests.init(a, &c.story, c.memory.?.store(), &c.host, &c.owners, .{});
    const q = &c.quests.?;
    for (0..n) |i| _ = try q.start(.fromRaw(0), &.{.{ .ref = i + 1 }});
    var clock = std.Io.Clock.Timestamp.now(io, .awake);
    _ = try q.step();
    const started = clock.untilNow(io).raw.nanoseconds;
    const running = counting.live;
    try c.memory.?.set(c.story.factNamed("closed").?, .{ .boolean = true });
    clock = std.Io.Clock.Timestamp.now(io, .awake);
    _ = try q.step();
    const ended = clock.untilNow(io).raw.nanoseconds;
    var kept: usize = 0;
    for (c.memory.?.keyed) |k| kept += k.count();
    try w.print("{d} instances of a repeat quest: their first step {d} ms, holding {d} MB; all ended in one step {d} ms, then {d} MB, {d} values of facts kept per instance among it\n", .{ n, @divTrunc(started, 1_000_000), running >> 20, @divTrunc(ended, 1_000_000), counting.live >> 20, kept });
}

// An allocator that counts the bytes it holds now.
const Counting = struct {
    child: std.mem.Allocator,
    live: usize = 0,

    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ptr)); // safe: made by `allocator`
        const out = c.child.rawAlloc(len, alignment, ret) orelse return null;
        c.live += len;
        return out;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ptr)); // safe: made by `allocator`
        if (!c.child.rawResize(memory, alignment, len, ret)) return false;
        c.live = c.live - memory.len + len;
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ptr)); // safe: made by `allocator`
        const out = c.child.rawRemap(memory, alignment, len, ret) orelse return null;
        c.live = c.live - memory.len + len;
        return out;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ptr)); // safe: made by `allocator`
        c.child.rawFree(memory, alignment, ret);
        c.live -= memory.len;
    }
};
