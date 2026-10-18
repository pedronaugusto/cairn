//! A game's vocabulary for riverrun's `addStory`, with cairn registered
//! beside the game's own tags and its activation keys: what cairn's
//! development compiles its stories with, as a game's build would.

const riverrun = @import("riverrun-compiler");
const cairn = @import("cairn-compiler");

// the game's own: a section the phone shows
const schema: riverrun.check.Schema = .{ .keys = &.{.{ .name = "phone", .on = .{ .section = true } }} };

pub const options: riverrun.check.Options = .{
    .schema = &schema,
    // what the world can turn on and off for a quest, as the game's manifest lists it
    .things = &.{.{ .kind = "activation", .ids = &.{ "spawn_stranger", "pin_letter", "pin_target", "open_gate" } }},
};
pub const packages: []const riverrun.Package = &.{cairn.package};
