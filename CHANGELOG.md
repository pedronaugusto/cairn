# Changelog

All notable changes are documented here, following Keep a Changelog 1.1.0.

## [Unreleased]

### Added

- Quests written in `.river` files and run over riverrun's facts: stages, objectives, outcomes and failures,
  latching or `live`, ordered by `after`, with `since` and `before`.
- Roles given when a quest starts, repeat quests with an instance per thing of the quest's own kind, and rules many
  quests share, inherited by the roles they read.
- Evaluation only where what a stage reads has changed; everything kept as the story's facts, so quests save and
  restore with the rest.
- Checks when compiling: each stage's kind, `after`, roles, endings that can hold at once, stages that read each
  other round, and quests that can get stuck, reported with the way there.
- A quest names at most 64 activation keys in its stages' `active` and `keeps` together, each counted once: the
  checker, the compiled block and the runtime hold the same bound, so a run never drops a key.
- The game's calls as play commands in `riverrun play`: `:start` and `:bind`, with `--call` on the command line.
- The manual's chapter on quests, [docs/manual/10-quests.md](docs/manual/10-quests.md), every block held by the
  test step.
