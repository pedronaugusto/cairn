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
- Played without the game by `riverrun play`, as the game runs them: a stage reached is told as it happens, with
  its journal lines and its effects, and a quest that starts itself is given a stand-in for each role.

The design is [docs/design.md](docs/design.md). A writer learns quests from riverrun's manual, whose chapter on them
is cairn's: [docs/manual/10-quests.md](docs/manual/10-quests.md).

## Install

Requires Zig 0.17. Fetch with `zig fetch --save git+https://github.com/pedronaugusto/cairn`. The runtime is the
`cairn` module, on aegis and riverrun. A story's build lists `cairn.package` in its vocabulary and hands
`cairn.compiler(dep)` to riverrun's `addStory` as the `cairn-compiler` package, both on the riverrun the build
stands on.

## Scope

cairn keeps quests as the story's facts and adds no store, save format or network of its own; it keeps no time
(any clock fact that never goes back serves) and draws nothing.

## Testing

`bay test` runs the unit suite: stages, roles, repeats and inherited rules; the checks on compiled stories through
riverrun's `addStory`; a story told to each of its endings; properties of the compiled block (a plan written
reads back as itself, and any bytes read to a plan or are refused, a block whole or not at all); and the
manual's chapter, its stories checked and every run it shows pinned (`bay dev manual-test` alone).

## Stability

cairn is 0.x and tracks Zig 0.17.x. A breaking change comes only in a minor release
(0.1 to 0.2), with a CHANGELOG entry saying what changed and what to write instead; a
patch release never breaks.

## Licence

MIT. See [LICENSE](LICENSE).
