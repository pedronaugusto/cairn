# cairn

cairn runs quests written in `.river` files, over riverrun's facts: what a player is trying to do, how far they have
got, how it ended, and what the world shows because of it.

- Stages reached when their conditions over the facts hold: stages, objectives, outcomes and failures, latching or
  `live`, ordered by `after`; `since` counts from a stage and `before` orders two.
- Roles given when a quest starts, and quests that repeat, each instance kept per a thing of the quest's own kind;
  rules many quests share, inherited by the roles they read.
- Evaluated by riverrun's react layer only where what a stage reads has changed: a fact, a key of a fact kept per
  thing, a query's stamp, or a clock reaching the number it is compared with.
- Everything kept as the story's facts, so quests save and restore as the rest do and a save survives a patch; the
  active set and the journal derived from them.
- Checked when compiling: each stage's kind, `after`, roles, endings that can hold at once, stages that read each
  other round through a live one, and quests that can get stuck, reported with the way there.
- Written in a story's `.river` files and registered with a story's build as one package, `cairn.package`, whose
  compiler side is the `cairn-compiler` module, from `compiler(dep)` in cairn's `build.zig`, on the one riverrun a
  story's build stands on; run by `cairn.Quests`.

The design is [docs/design.md](docs/design.md).
