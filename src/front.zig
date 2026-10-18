//! cairn's compiler side: what it adds to a story's language and its build,
//! registered as one package. A game's vocabulary lists `package`, and its
//! build hands this module to `addStory` from cairn's `compiler`; the quest
//! kinds, cairn's judges, its check and its pass come with it. Only a build
//! needs this; at run time `cairn.Quests` reads what the pass wrote.

const vocabulary = @import("front/vocabulary.zig");

/// What a vocabulary registers: `pub const packages = &.{cairn.package}`.
pub const package = vocabulary.package;
/// The `quest` and `quest rules` kinds, for a vocabulary that composes its own package from cairn's.
pub const quest = vocabulary.quest;
pub const rules = vocabulary.rules;
/// A checked story's quests, as cairn's pass reads them, for tools.
pub const read = @import("front/read.zig");

test {
    _ = vocabulary;
    _ = read;
    _ = @import("front/written.zig");
    _ = @import("front/declare.zig");
    _ = @import("front/judge.zig");
    _ = @import("front/analysis.zig");
    _ = @import("front/model.zig");
    _ = @import("front/emit.zig");
    _ = @import("front/pass.zig");
    _ = @import("front/front_test.zig");
}
