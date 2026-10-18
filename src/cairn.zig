//! cairn: quests over riverrun's facts. What a player is trying to do, how far
//! they have got, how it ended, and what the world shows because of it, as
//! stages reached when their conditions over the facts hold, evaluated by
//! riverrun's react layer only where what they read has changed. A story's
//! quests are written in `.river` files and compiled by riverrun with cairn's
//! compiler side registered (`cairn-compiler`); this is what runs them.

pub const Quests = @import("cairn/Quests.zig");
pub const QuestId = Quests.QuestId;
pub const StageId = Quests.StageId;
pub const Instance = Quests.Instance;
pub const Status = Quests.Status;
pub const Event = Quests.Event;
pub const Step = Quests.Step;
pub const Entry = Quests.Entry;
pub const Options = Quests.Options;
pub const Error = Quests.Error;
pub const max_rounds = Quests.max_rounds;
/// The active set's keys and entries.
pub const Active = @import("cairn/Active.zig");
/// cairn's block in a compiled story, which its compile pass writes and `Quests` reads.
pub const block = @import("cairn/block.zig");

test {
    _ = Quests;
    _ = Active;
    _ = block;
    _ = @import("cairn/load.zig");
}
