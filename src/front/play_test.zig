//! cairn's quests played as `riverrun play` plays them, with the game's calls
//! into cairn given as the play's commands: any script of them, good and bad,
//! gives a transcript and a named ending; what cairn asks while it works out a
//! news is told under that news; an error in a stage's effects is placed at
//! the effect that met it.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const tools = @import("riverrun-tools");
const shakedown = @import("shakedown");
const vocabulary = @import("vocabulary.zig");

const gpa = std.testing.allocator;
const gen = shakedown.gen;
const check = riverrun.check;

const Vocabulary = struct {
    pub const options: check.Options = .{ .things = &.{.{ .kind = "activation", .ids = &.{ "pin_target", "spawn" } }} };
    pub const packages: []const riverrun.Package = &.{vocabulary.package};
};
const joined = riverrun.join(Vocabulary);

/// A quest the game starts with its giver, a board of bounties it posts again and again, a quest that starts itself
/// once the game gives its role, and a scene that waits.
const board =
    \\facts (world):
    \\  dead(person): bool   (game)
    \\  day:  int            (clock)
    \\  gold: int
    \\  met: bool            (game)
    \\extern:
    \\  name(who: ref of person) -> text
    \\
    \\== delivery (quest)
    \\  [start host] [scope world]
    \\facts (world):
    \\  giver: ref of person   (role)
    \\= taken        when { true }
    \\  [stage]
    \\  A letter for the mill, from {name(giver)}.
    \\= delivered    when { gold > 0 }
    \\  [outcome] [after taken]
    \\  Delivered.
    \\
    \\== bounty (quest)
    \\  [repeat] [scope world]
    \\facts (world):
    \\  target: ref of person   (role)
    \\= posted       when { true }
    \\  [stage] [active pin_target]
    \\  A price on {name(target)}.
    \\= claimed      when { dead(target) }
    \\  [outcome] [after posted]
    \\  [gold += 50]
    \\  Paid.
    \\= expired      when { since(posted, day) > 3 and not dead(target) }
    \\  [fails]
    \\  The board took the notice down.
    \\
    \\== stranger (quest)
    \\  [scope world]
    \\facts (world):
    \\  who: ref of person   (role)
    \\= noticed      when { met }
    \\  [stage]
    \\  Somebody, {name(who)}, at the door.
    \\= gone         when { dead(who) }
    \\  [outcome] [after noticed]
    \\  Gone.
    \\
    \\== board
    \\+ Look at the board.
    \\  -> board
    \\* Leave.
    \\  -> end
    \\
;

/// A row of a script: the game's calls into cairn, right and wrong (a quest that is not there, a role given a thing
/// of another kind, a quest that runs once started again, a role missing or given none), and the rest a player
/// types.
fn anyRow(s: *shakedown.Source) []const u8 {
    return gen.oneOf(s, []const u8, &.{
        ":start delivery giver=hilde",
        ":start bounty target=wolf",
        ":start bounty target = ulf",
        ":start bounty target=pin_target",
        ":start nowhere giver=hilde",
        ":start delivery",
        ":start delivery giver=none",
        ":start stranger who=tom",
        ":bind stranger who=tom",
        ":bind stranger who=spawn",
        ":bind delivery giver=hilde",
        ":set dead(wolf) = true",
        ":set met = true",
        ":wait 2",
        "1",
        "2",
        ":back",
        ":restart",
        ":help",
    });
}

test "any script of the game's calls into cairn, right and wrong, gives a transcript and a named ending, and what cairn asks is told under its news" {
    try shakedown.check(gpa, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var m, var out = try tools.Manuscript.build(gpa, &.{.{ .path = "board.river", .text = board }}, joined, .development);
            defer m.deinit();
            defer if (out) |*o| o.deinit(gpa);
            const compiled = &(out orelse return error.TestStoryRefused);
            var loaded: tools.walk.Loaded = undefined;
            try loaded.init(gpa, compiled.graph, compiled.words);
            defer loaded.deinit();
            var p: tools.Play = undefined;
            try p.init(gpa, &loaded, .{ .start = loaded.story.sectionNamed("board").?, .running = joined.running });
            defer p.deinit();
            const t: tools.transcript.Transcript = .{ .play = &p, .files = m.files, .where = &compiled.where };
            const rows = try a.alloc(tools.script.Row, gen.intRange(case.source, usize, 0, 14));
            for (rows, 1..) |*r, n| r.* = .{ .text = anyRow(case.source), .path = "script", .line = @intCast(n) };
            var text: std.Io.Writer.Allocating = .init(a);
            const ending = try tools.script.run(gpa, &text.writer, &t, &p, rows);
            const written = text.written();
            // a query cairn asks, while it words a journal, is told under the news it is of, never before it
            var lines = std.mem.splitScalar(u8, written, '\n');
            var under_news = false;
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "! ")) under_news = true else if (line.len > 0 and line[0] != ' ') under_news = false;
                if (std.mem.startsWith(u8, line, "? name(")) {
                    std.debug.print("--- a query told on its own, before the news it is of\n{s}", .{written});
                    return error.TestUnexpectedResult;
                }
                if (std.mem.startsWith(u8, line, "  ? name(") and !under_news) {
                    std.debug.print("--- a query told under no news\n{s}", .{written});
                    return error.TestUnexpectedResult;
                }
            }
            case.reached("played");
            if (std.mem.find(u8, written, "  ? name(") != null) case.reached("a query under its news");
            if (std.mem.find(u8, written, "! started bounty(2)") != null) case.reached("a repeat quest started twice");
            if (std.mem.find(u8, written, "! started delivery") != null) case.reached("a quest the game starts");
            if (ending == .refused) {
                for ([_]struct { []const u8, []const u8 }{
                    .{ "there is no quest `nowhere`", "a quest that is not there" },
                    .{ "takes one of the kind `person`", "a role given a thing of another kind" },
                    .{ "has started already", "a quest started again" },
                    .{ "is missing", "a role missing" },
                    .{ "never none", "a role given none" },
                }) |r| if (std.mem.find(u8, written, r[0]) != null) case.reached(r[1]);
            }
        }
    }.one, .{ .cases = 400, .seed = 0xb0a4d, .reach = &.{ "played", "a query under its news", "a repeat quest started twice", "a quest the game starts", "a quest that is not there", "a role given a thing of another kind", "a quest started again", "a role missing", "a role given none" } });
}

test "an error in a stage's effects is placed at the effect that met it, the Nth of the stage's" {
    try shakedown.check(gpa, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(a,
                \\facts (world):
                \\  big: int
                \\  n: int
                \\  met: bool   (game)
                \\const:
                \\  most = 9223372036854775807
                \\
                \\== q (quest)
                \\  [scope world]
                \\= seen   when { met }
                \\  [stage]
                \\
            );
            const count = gen.intRange(case.source, usize, 1, 5);
            const bad = gen.intRange(case.source, usize, 0, count - 1);
            var row: u32 = @intCast(std.mem.countScalar(u8, text.items, '\n') + 1);
            var col: u32 = 3;
            var want: [2]u32 = undefined;
            const together = gen.boolean(case.source);
            for (0..count) |i| {
                if (i == 0 or !together) {
                    if (i > 0) {
                        try text.append(a, '\n');
                        row += 1;
                    }
                    try text.appendSlice(a, "  ");
                    col = 3;
                } else {
                    try text.append(a, ' ');
                    col += 1;
                }
                const effect = if (i == bad) try a.dupe(u8, "[big += 1]") else try a.print("[n = {d}]", .{i});
                if (i == bad) want = .{ row, col };
                try text.appendSlice(a, effect);
                col += @intCast(effect.len);
            }
            try text.appendSlice(a, "\n  Seen.\n\n== a\n[big = most]\n* Go.\n  -> end\n");
            var m, var out = try tools.Manuscript.build(gpa, &.{.{ .path = "q.river", .text = text.items }}, joined, .development);
            defer m.deinit();
            defer if (out) |*o| o.deinit(gpa);
            const compiled = &(out orelse {
                for (m.diags.list.items) |d| std.debug.print("{s}\n", .{d.message});
                return error.TestStoryRefused;
            });
            var loaded: tools.walk.Loaded = undefined;
            try loaded.init(gpa, compiled.graph, compiled.words);
            defer loaded.deinit();
            var p: tools.Play = undefined;
            try p.init(gpa, &loaded, .{ .start = loaded.story.sectionNamed("a").?, .running = joined.running });
            defer p.deinit();
            const t: tools.transcript.Transcript = .{ .play = &p, .files = m.files, .where = &compiled.where };
            var told: std.Io.Writer.Allocating = .init(a);
            const ending = try tools.script.run(gpa, &told.writer, &t, &p, &.{.{ .text = ":set met = true" }});
            try std.testing.expectEqual(tools.script.Ending.stopped, ending);
            const expected = try a.print("q.river:{d}:{d}-{d}:{d}: error:", .{ want[0], want[1], want[0], want[1] + 10 });
            std.testing.expect(std.mem.find(u8, told.written(), expected) != null) catch |e| {
                std.debug.print("--- story\n{s}\n--- want {s}\n--- got\n{s}", .{ text.items, expected, told.written() });
                return e;
            };
            if (bad > 0) case.reached("not the first");
        }
    }.one, .{ .cases = 100, .seed = 0xe55, .reach = &.{"not the first"} });
}
