//! Quests written in `.river`, checked and compiled with cairn registered as
//! a game's vocabulary registers it: each thing cairn refuses, in the
//! smallest story that shows it, where it is written; and quests compiled,
//! loaded and run, to what only running shows.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const runtime = @import("riverrun");
const cairn = @import("cairn");
const vocabulary = @import("vocabulary.zig");

const gpa = std.testing.allocator;
const check = riverrun.check;
const facts = runtime.facts;
const Severity = riverrun.syntax.source.Severity;

/// A vocabulary with cairn registered, and the host's activation keys.
const Vocabulary = struct {
    pub const options: check.Options = .{ .things = &.{.{ .kind = "activation", .ids = &.{ "spawn", "pin" } }} };
    pub const packages: []const riverrun.Package = &.{vocabulary.package};
};
const joined = riverrun.join(Vocabulary);

pub const Built = struct {
    arena: std.heap.ArenaAllocator,
    diags: riverrun.syntax.Diagnostics,
    checked: ?check.Checked = null,
    compiled: ?riverrun.compile.Compiled = null,

    pub fn deinit(b: *Built) void {
        if (b.compiled) |*c| c.deinit(gpa);
        if (b.checked) |*c| c.deinit();
        b.diags.deinit(gpa);
        b.arena.deinit();
    }

    fn print(b: *const Built) void {
        for (b.diags.list.items) |d| std.debug.print("  {t} {d}:{d}: {s}\n", .{ d.severity, d.span.line, d.span.col, d.message });
    }

    /// A diagnostic with this message, at this place.
    fn has(b: *const Built, severity: Severity, line: u32, col: u32, message: []const u8) !void {
        for (b.diags.list.items) |d| {
            if (d.severity == severity and d.span.line == line and d.span.col == col and std.mem.eql(u8, d.message, message)) return;
        }
        std.debug.print("wanted {t} {d}:{d}: {s}\n", .{ severity, line, col, message });
        b.print();
        return error.TestMissingDiagnostic;
    }

    /// The one diagnostic there is, which must be this one.
    fn only(b: *const Built, severity: Severity, line: u32, col: u32, message: []const u8) !void {
        if (b.diags.list.items.len != 1) {
            b.print();
            return error.TestExpectedOneDiagnostic;
        }
        try b.has(severity, line, col, message);
    }
};

/// Reads, checks (riverrun's checker, cairn's within it) and, when nothing is wrong, compiles `text`.
pub fn build(text: []const u8) !Built {
    var b: Built = .{ .arena = .init(gpa), .diags = .{} };
    errdefer b.deinit();
    const tree = try b.arena.allocator().create(riverrun.syntax.ast.File);
    tree.* = try riverrun.syntax.parse(b.arena.allocator(), gpa, &b.diags, 0, "a.river", text);
    b.checked = try check.run(gpa, &b.diags, tree[0..1], joined.options);
    if (b.diags.errors() == 0) b.compiled = try riverrun.compile.run(gpa, &b.diags, &b.checked.?, .{ .passes = joined.passes });
    return b;
}

// ---------------------------------------------------------------- what cairn refuses

test "a stage is one kind, reached by its condition, its body its journal and its effects" {
    var b = try build(
        \\facts:
        \\  met: bool   (game)
        \\== q (quest)
        \\= a   when { met }                  # stage · objective
        \\= b   when { met }                  # outcome · live
        \\= c   when { met }                  # stage · optional
        \\= d                                 # stage
        \\= e   when { met }                  # fails
        \\  * Run.
        \\    -> end
    );
    defer b.deinit();
    try b.has(.err, 4, 3, "`a` is a stage, an objective, an outcome or a failure: mark it with one of `stage`, `objective`, `outcome` or `fails`");
    try b.has(.err, 5, 3, "`b` ends the quest, which stays ended: an ending is never `live`");
    try b.has(.err, 6, 3, "only an objective is `optional`: `c` is a stage");
    try b.has(.err, 7, 3, "`d` is reached when its condition holds: `= d when { … }`");
    try b.has(.err, 9, 3, "under a stage go its journal's lines and what reaching it does, `~ …`: nothing else");
}

test "`after` names stages of the quest and never goes round" {
    var b = try build(
        \\facts:
        \\  met: bool   (game)
        \\== q (quest)
        \\= a   when { met }   # stage
        \\= b   when { met }   # stage · after a, x
        \\= c   when { met }   # outcome · after b
    );
    defer b.deinit();
    try b.only(.err, 5, 42, "`x` is not a stage of `q`");
    var round = try build(
        \\facts:
        \\  met: bool   (game)
        \\== q (quest)
        \\= a   when { met }   # stage · after c
        \\= b   when { met }   # stage · after a
        \\= c   when { met }   # outcome · after b
    );
    defer round.deinit();
    try round.only(.err, 4, 3, "`a`'s `after` comes round to it again: what comes after what in `q` goes one way");
}

test "activation keys are the host's, and `follows` names shared rules" {
    var b = try build(
        \\facts:
        \\  met: bool   (game)
        \\== q (quest)                 # follows a, nobody
        \\= seen   when { met }        # outcome · active spawn, spwan
        \\== a
        \\-> end
    );
    defer b.deinit();
    try b.has(.err, 4, 57, "the host has no activation key `spwan`");
    try b.has(.err, 3, 40, "`a` is not `(quest rules)`");
    try b.has(.err, 3, 43, "`nobody` is not a section");
}

test "a quest's facts are kept in the scope its stages are" {
    var b = try build(
        \\facts:
        \\  met: bool   (game)
        \\== q (quest)          # scope player
        \\facts (life):
        \\  asked: bool
        \\= seen   when { met and asked }    # outcome
        \\== a
        \\~ q.asked = true
        \\-> end
    );
    defer b.deinit();
    try b.only(.err, 5, 3, "`q`'s facts are saved with its stages: declare them `facts (player):`, the scope its `scope` names");
}

test "two endings that can hold at once are refused, where it can be decided" {
    var b = try build(
        \\facts:
        \\  met:  bool   (game)
        \\  told: bool   (game)
        \\  hour: int    (game)
        \\== q (quest)
        \\= named   when { met and told }          # outcome
        \\= gone    when { met }                   # fails
        \\= late    when { hour > 3 and not met }  # fails
    );
    defer b.deinit();
    // `late` against `named` and `gone` cannot hold: it is never said
    try b.only(.err, 7, 3, "`named` and `gone` can hold at once, and a quest ends once: make their conditions exclusive");
}

test "a quest that can get stuck is refused, with the way there" {
    var b = try build(
        \\facts:
        \\  dead: bool
        \\  asked: bool
        \\== q (quest)
        \\= met     when { asked }                # stage
        \\= saved   when { met and not dead }     # outcome
        \\== a
        \\* Ask.
        \\  ~ asked = true
        \\  -> end
        \\* Kill him.
        \\  ~ dead = true
        \\  -> end
    );
    defer b.deinit();
    try b.only(.err, 4, 4, "`q` can get stuck once `dead` holds: no outcome or failure can be reached from there");
    // a failure written for it, and it never is
    var fixed = try build(
        \\facts:
        \\  dead: bool
        \\  asked: bool
        \\== q (quest)
        \\= met     when { asked }                # stage
        \\= saved   when { met and not dead }     # outcome
        \\= lost    when { dead }                 # fails
        \\== a
        \\* Ask.
        \\  ~ asked = true
        \\  -> end
        \\* Kill him.
        \\  ~ dead = true
        \\  -> end
    );
    defer fixed.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixed.diags.list.items.len);
}

test "a stage nothing can reach is said, and a quest that never ends" {
    var b = try build(
        \\facts:
        \\  lit: bool
        \\== q (quest)
        \\= dark    when { not lit }   # stage
        \\= bright  when { lit }       # stage
        \\== a
        \\~ lit = false
        \\-> end
    );
    defer b.deinit();
    try b.has(.warning, 3, 4, "`q` has no outcome and no failure, so it never ends");
    try b.has(.warning, 5, 3, "`bright` can never be reached: nothing the story does makes its condition hold");
    try std.testing.expectEqual(@as(usize, 0), b.diags.errors());
}

test "live stages that read each other round are refused" {
    var b = try build(
        \\facts:
        \\  lamp: bool   (game)
        \\== q (quest)
        \\= lit      when { lamp and not shadow }   # stage · live
        \\= shadow   when { lit }                   # stage · live
        \\= done     when { lamp }                  # outcome
    );
    defer b.deinit();
    try b.has(.err, 4, 3, "`lit` is live and its condition comes back to it through other stages': they could keep changing each other for ever");
}

test "a shared stage is inherited by every quest with its roles, of their kinds" {
    var b = try build(
        \\facts:
        \\  dead(person): bool   (game)
        \\  met: bool   (game)
        \\== everyone (quest rules)
        \\facts:
        \\  giver: ref of person   (role)
        \\= abandoned   when { dead(giver) }   # fails
        \\== pelts (quest)
        \\facts:
        \\  giver: ref of place   (role)
        \\= done   when { met }   # outcome
    );
    defer b.deinit();
    try b.only(.err, 8, 4, "`pelts` inherits `abandoned` from `everyone`, whose `giver` is not the same kind of thing as its own");
}

test "a watched condition asks only queries that say what they read" {
    var b = try build(
        \\extern:
        \\  gold() -> int
        \\== q (quest)
        \\= rich   when { gold() > 100 }   # outcome
    );
    defer b.deinit();
    try b.only(.err, 4, 17, "`gold` is asked by a watched condition, which wakes only when what it reads changes: declare what it reads, `(reads …)`");
}

// ---------------------------------------------------------------- running

/// A story compiled and its quests run over a store of its own, its things resolved and no externs bound.
const Played = struct {
    built: Built,
    story: runtime.story.Story,
    arena: std.heap.ArenaAllocator,
    memory: facts.Memory,
    host: runtime.run.Host,
    owners: [facts.max_scopes]u64 = @splat(0),
    quests: cairn.Quests,

    fn init(p: *Played, text: []const u8, options: cairn.Options) !void {
        p.built = try build(text);
        errdefer p.built.deinit();
        const compiled = p.built.compiled orelse {
            p.built.print();
            return error.TestStoryRefused;
        };
        p.story = try .init(compiled.graph, .{});
        p.arena = .init(gpa);
        errdefer p.arena.deinit();
        p.memory = try .init(gpa, try p.story.schema(p.arena.allocator()));
        errdefer p.memory.deinit();
        p.host = .none;
        const Things = struct {
            fn resolve(_: ?*anyopaque, _: []const u8, id: []const u8) ?u64 {
                return id.len;
            }
        };
        try p.host.resolveStory(gpa, &p.story, .{ .user = null, .resolve = Things.resolve }, null);
        errdefer p.host.deinit();
        p.quests = try .init(gpa, &p.story, p.memory.store(), &p.host, &p.owners, options);
    }

    fn deinit(p: *Played) void {
        p.quests.deinit();
        p.host.deinit();
        p.memory.deinit();
        p.arena.deinit();
        p.built.deinit();
    }

    fn fact(p: *const Played, name: []const u8) facts.FactId {
        return p.story.factNamed(name).?;
    }

    fn set(p: *Played, name: []const u8, v: facts.Value) !void {
        try p.memory.set(p.fact(name), v);
    }

    fn quest(p: *const Played, name: []const u8) cairn.Instance {
        return .{ .quest = p.quests.questNamed(name).? };
    }

    fn stage(p: *const Played, q: []const u8, name: []const u8) cairn.StageId {
        return p.quests.stageNamed(p.quest(q).quest, name).?;
    }
};

test "a live stage follows its condition, and the current stage falls back when it no longer holds" {
    var p: Played = undefined;
    try p.init(
        \\facts:
        \\  lamp: bool   (game)
        \\  out:  bool   (game)
        \\== cellar (quest)
        \\= entered   when { lamp or out }        # stage
        \\= carrying  when { lamp }               # objective · live · after entered · active pin
        \\= left      when { out }                # outcome
    , .{});
    defer p.deinit();
    const i = p.quest("cellar");
    try p.set("lamp", .{ .boolean = true });
    _ = try p.quests.step();
    try std.testing.expectEqual(p.stage("cellar", "carrying"), p.quests.current(i).?);
    try std.testing.expectEqual(@as(usize, 1), p.quests.activeSet().len);
    try p.set("lamp", .{ .boolean = false });
    const s = try p.quests.step();
    try std.testing.expect(s.events[0].what == .left);
    try std.testing.expectEqual(p.stage("cellar", "entered"), p.quests.current(i).?);
    try std.testing.expectEqual(@as(usize, 0), p.quests.activeSet().len);
    try p.set("lamp", .{ .boolean = true });
    _ = try p.quests.step();
    try std.testing.expect(p.quests.reached(i, p.stage("cellar", "carrying")));
}

test "two endings reached in one step, where the checker could not tell, are a named error" {
    var p: Played = undefined;
    try p.init(
        \\facts:
        \\  hour: int   (game)
        \\== night (quest)
        \\= dawn    when { hour > 5 }   # outcome
        \\= lost    when { hour > 4 }   # fails
    , .{});
    defer p.deinit();
    try p.set("hour", .{ .int = 9 });
    try std.testing.expectError(error.TwoEndings, p.quests.step());
}

test "a step reaches stages to a fixed point, bounded by a named error" {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try text.writer.writeAll("facts:\n  go: bool   (game)\n== long (quest)\n= s0   when { go }   # stage\n");
    for (1..cairn.max_rounds + 1) |k| try text.writer.print("= s{d}   when {{ s{d} }}   # stage\n", .{ k, k - 1 });
    try text.writer.print("= done   when {{ s{d} }}   # outcome\n", .{cairn.max_rounds});
    var p: Played = undefined;
    try p.init(text.written(), .{});
    defer p.deinit();
    try p.set("go", .{ .boolean = true });
    try std.testing.expectError(error.NoFixedPoint, p.quests.step());
}

test "a budget changes when stages are reached, never what" {
    var p: Played = undefined;
    try p.init(
        \\facts:
        \\  go: bool   (game)
        \\== q (quest)
        \\= a   when { go }   # stage
        \\= b   when { go }   # stage
        \\= c   when { a and b }   # outcome
    , .{ .budget = 1 });
    defer p.deinit();
    const i = p.quest("q");
    try p.set("go", .{ .boolean = true });
    var steps: usize = 0;
    while (p.quests.status(i) != .done) : (steps += 1) _ = try p.quests.step();
    try std.testing.expect(steps > 1);
    try std.testing.expect(p.quests.reached(i, p.stage("q", "a")) and p.quests.reached(i, p.stage("q", "b")));
}

test "a stage keeps its keys from it until the quest ends" {
    var p: Played = undefined;
    try p.init(
        \\facts:
        \\  met: bool   (game)
        \\  told: bool  (game)
        \\  done: bool  (game)
        \\== q (quest)
        \\= a   when { met }    # stage · keeps pin
        \\= b   when { told }   # stage · active spawn · after a
        \\= c   when { done }   # outcome
    , .{});
    defer p.deinit();
    try p.set("met", .{ .boolean = true });
    _ = try p.quests.step();
    try p.set("told", .{ .boolean = true });
    _ = try p.quests.step();
    try std.testing.expectEqual(@as(usize, 2), p.quests.activeSet().len);
    try p.set("done", .{ .boolean = true });
    const s = try p.quests.step();
    var gone: usize = 0;
    for (s.events) |e| gone += @intFromBool(e.what == .deactivated);
    try std.testing.expectEqual(@as(usize, 2), gone);
    try std.testing.expectEqual(@as(usize, 0), p.quests.activeSet().len);
}

const before_patch =
    \\facts (life):
    \\  met: bool   (game)
    \\  seen_it: bool   (game)
    \\== q (quest)          # scope life
    \\= noticed  when { met }              # stage
    \\= found    when { met and seen_it }  # stage · after noticed
    \\= done     when { found }            # outcome · after found
;

const after_patch =
    \\facts (life):
    \\  met: bool   (game)
    \\  seen_it: bool   (game)
    \\== q (quest)          # scope life
    \\= noticed   when { met }                 # stage
    \\= found     when { met }                 # stage · after noticed
    \\= recalled  when { met }                 # stage · after noticed
    \\= done      when { found and recalled }  # outcome · after found
;

test "a save survives a patch: a stage whose condition now holds is reached at the first step" {
    var old: Played = undefined;
    try old.init(before_patch, .{});
    defer old.deinit();
    try old.set("met", .{ .boolean = true });
    _ = try old.quests.step();
    try std.testing.expectEqual(cairn.Status.active, old.quests.status(old.quest("q")));
    var saved: std.Io.Writer.Allocating = .init(gpa);
    defer saved.deinit();
    const life = old.memory.schema.scopeNamed("life").?;
    try facts.snapshot.write(&old.memory, &saved.writer, life, old.story.hash());
    // the patch fixes `found` and adds `noticed`; the save is restored under it with no migration
    var new: Played = undefined;
    try new.init(after_patch, .{});
    defer new.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = try facts.snapshot.read(&new.memory, arena.allocator(), new.memory.schema.scopeNamed("life").?, new.story.hash(), saved.written());
    try new.quests.restored();
    try std.testing.expectEqual(cairn.Status.active, new.quests.status(new.quest("q")));
    _ = try new.quests.step();
    try std.testing.expectEqual(cairn.Status.done, new.quests.status(new.quest("q")));
}

test "a quest that starts itself, restored before it started, still starts itself" {
    var p: Played = undefined;
    try p.init(
        \\facts (life):
        \\  met: bool   (game)
        \\== q (quest)      # scope life
        \\= seen   when { met }   # outcome
    , .{});
    defer p.deinit();
    _ = try p.quests.step();
    try p.quests.restored();
    try p.set("met", .{ .boolean = true });
    _ = try p.quests.step();
    try std.testing.expectEqual(cairn.Status.done, p.quests.status(p.quest("q")));
}

test "the story's dependency index finds the stages that read a fact" {
    var p: Played = undefined;
    try p.init(
        \\facts:
        \\  met: bool   (game)
        \\== q (quest)
        \\= a   when { met }   # stage
        \\= b   when { a }     # outcome
    , .{});
    defer p.deinit();
    const readers = p.quests.readers(p.fact("met"));
    try std.testing.expectEqual(@as(usize, 1), readers.len);
    try std.testing.expectEqual(@as(u8, 0), readers[0].stage);
    try std.testing.expectEqual(@as(u8, 1), p.quests.readers(p.fact("q.a"))[0].stage);
}
