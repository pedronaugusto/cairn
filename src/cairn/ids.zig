//! What cairn's runtime knows a quest, a stage and an instance by.

const aegis = @import("aegis");
const Value = @import("riverrun").facts.Value;

/// A quest, by its place in the story's quests.
pub const QuestId = aegis.id.Id(enum { quest }, u32);
/// A stage, by its place in its quest: its own in the order written, then those it inherits.
pub const StageId = aegis.id.Id(enum { stage }, u8);

/// One run of a quest: the quest, and the thing it is kept per where it repeats; 0 for one that runs once.
pub const Instance = struct {
    quest: QuestId,
    key: u64 = Value.no_ref,

    pub fn eql(a: Instance, b: Instance) bool {
        return a.quest.eql(b.quest) and a.key == b.key;
    }
};
