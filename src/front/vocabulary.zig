//! What cairn adds to a story's language: the `quest` kind of section, the
//! `quest rules` kind that many quests share, their tags and their builtins,
//! and cairn's check and pass, registered as one package. No grammar: a
//! quest is a section whose parts are its stages, whose own facts are its
//! facts and its roles, and whose lines are its journal.
//!
//!     == the_stranger (quest)                                 # title "Who was he?"
//!     facts:
//!       stranger: ref of person   (role)
//!     = noticed      when { met }                             # stage · active spawn_stranger
//!     = the_letter   when { found has letter }                # objective · after noticed
//!     = named        when { the_letter and since(noticed, day) < 3 }   # outcome · after the_letter
//!
//! A stage's name is true once it is reached, so stages compose without
//! flags of their own, and `since` and `before` count from them and order
//! them. cairn's judges hold `after`, `follows` and the activation keys to
//! the story, so a typo fails with its file and line.

const riverrun = @import("riverrun-compiler");
const declare = @import("declare.zig");
const judge = @import("judge.zig");
const pass = @import("pass.zig");
const written = @import("written.zig");

const Schema = riverrun.check.Schema;
const Key = Schema.Key;

const section: Schema.Places = .{ .section = true };
const part: Schema.Places = .{ .part = true };

// a stage's tags, a quest's own or a shared one: its kind, how it is reached, what it comes after, what it keeps
// active
const stage_keys = [_]Key{
    .{ .name = "stage", .on = part },
    .{ .name = "objective", .on = part },
    .{ .name = "outcome", .on = part },
    .{ .name = "fails", .on = part },
    .{ .name = "live", .on = part },
    .{ .name = "optional", .on = part },
    .{ .name = "after", .on = part, .value = .{ .judge = judge.after }, .count = .many },
    .{ .name = "active", .on = part, .value = .{ .judge = judge.keys }, .count = .many },
    .{ .name = "keeps", .on = part, .value = .{ .judge = judge.keys }, .count = .many },
};

const quest_schema: Schema = .{
    .keys = &(stage_keys ++ [_]Key{
        // the quest: what the journal calls it, the scope its stages are kept in, whether it runs many times, who
        // starts it, and the shared rules it follows beside those its roles bring
        .{ .name = "title", .on = section, .value = .text },
        .{ .name = "scope", .on = section, .value = .word },
        .{ .name = "repeat", .on = section },
        .{ .name = "start", .on = section, .value = .{ .words = &.{ "itself", "host" } } },
        .{ .name = "follows", .on = section, .value = .{ .judge = judge.follows }, .count = .many },
    }),
};

const rules_schema: Schema = .{ .keys = &stage_keys };

/// `since(stage, fact)`: how far an int fact has moved since the stage was reached, 0 before; over a `(clock)`
/// it waits in the clock's heap. `before(a, b)`: `a` was reached while `b` was not.
const builtins = [_]riverrun.check.Builtin{
    .{ .name = "since", .params = &.{ .part, .int_fact }, .returns = .int, .moves = 1 },
    .{ .name = "before", .params = &.{ .part, .part }, .returns = .boolean },
};

/// The kind a quest is, which declares the facts it keeps and is kept per instance where it repeats.
pub const quest: riverrun.check.Kind = .{ .name = written.quest, .schema = &quest_schema, .builtins = &builtins, .declare = declare.declare, .per = declare.per };

/// The kind shared rules are: stages every quest with the roles they read inherits.
pub const rules: riverrun.check.Kind = .{ .name = written.rules, .schema = &rules_schema };

/// What a game's vocabulary registers: `pub const packages = &.{cairn.package}`.
pub const package: riverrun.Package = .{
    .kinds = &.{ quest, rules },
    .check = .{ .run = pass.check },
    .compile = .{ .name = "cairn", .run = pass.compile },
};
