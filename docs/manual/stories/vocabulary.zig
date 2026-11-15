//! The vocabulary of the game the quests chapter's stories are written for:
//! the ferry at Hollin, as riverrun's manual has it, with cairn registered so
//! that a story may hold quests. Your game has its own.

const riverrun = @import("riverrun-compiler");
const cairn = @import("cairn-compiler");

// what the world shows or hides for a quest, as the game lists it: a mark on the map, the watch on the lookout. Its
// people are not listed: the fair's crowd is the game's, and a story may name any of them.
const things: []const riverrun.check.Things = &.{
    .{ .kind = "activation", .ids = &.{ "mill_marked", "watch_out", "parcel_marked" } },
};

// the game's subtitles hold 100 columns, and its choices 40
const width: riverrun.check.Width = .{ .line = 100, .choice = 40 };

pub const options: riverrun.check.Options = .{ .things = things, .width = width };

// the packages the game runs: cairn, for its quests
pub const packages: []const riverrun.Package = &.{cairn.package};
