# cairn's design

cairn runs quests: what a player is trying to do, how far they have got, what they found out, how it ended, and what
the world shows because of it. Quests are written in `.river` files and compiled by riverrun; their state is
riverrun's facts. cairn knows no engine and no game. This page is the design it is built to; nothing is built yet.

The bar is the largest role-playing games: thousands of quests, hundreds of thousands of facts, many writers, years
of patches, quests that resolve in many ways and react to everything, saves that survive every update, and a server
that is the authority. At that size the work per step must follow what changed, never how many quests exist.

## What it owns

cairn owns **progress**: stages, objectives, outcomes, failure, the journal, and which of the world's quest-driven
content is active. It owns no time, map, marker, reward, spawn or user interface: those are the host's, reached
through tags and emitted effects, as riverrun's mechanics are. *Protects:* one quest system for a terminal mystery
and an open world alike.

## What the large games taught

- **Quest graphs apart from scenes, both apart from facts.** Dialogue says things; quests track progress; facts are
  the one state both read. cairn is a package beside riverrun's dialogue runtime, over the same facts.
- **Progress declared over state, not pushed by scripts.** A stage is reached when its condition over facts holds.
  Nothing calls "advance the quest": the dialogue, the mechanic or the world sets facts, and quests follow. That is
  how a quest resolves the way the player found, not the way a script expected.
- **Roles filled at start.** A quest template names its roles (the victim, the reward, the place), bound when the
  quest starts, so one quest runs many times and generated quests are ordinary ones.
- **The world follows the quest.** A stage turns content on and off: people present, doors open, markers, lines a
  character can say. Stuck worlds come from content toggled by events and lost on load; so cairn gives the host the
  set of what is active, which the host reconciles to, and the set is always derivable from the facts.
- **Stuck quests are the classic bug.** A prerequisite gone for good, with no failure written, leaves a quest open
  for ever. cairn finds these when compiling.

## The language

A quest is a riverrun section of kind `quest`, which cairn registers with riverrun's compiler: its parts are its
stages, its lines its journal, its tags typed by cairn's schema. Nothing new is parsed, so riverrun's reader, checker,
line ids, translation and tools serve quests as they serve dialogue.

```
== the_stranger (quest)                                  # title "Who was he?"
role stranger: ref of person                             // bound by the host when the quest starts
facts:
  asked: set of margaret, tom, danny

= noticed      when { met }                              # stage
  A man nobody knows stood at the foot of the coffin.    # id q1a9
= the_letter   when { found has letter }                 # objective · after noticed
  A letter signed "L.", from a city she never lived in.  # id q1b2
= the_hands    when { said has gave }                    # objective · optional · after noticed
  He said the hands were the same.                       # id q1c4
= named        when { the_letter and the_hands }         # outcome · after the_letter
  ~ carried += his_name
  He was her son, from a life she didn't live.           # id q1d7
= gone         when { hour >= 6 and not the_letter }     # fails
  He left before dawn. Nobody had his number.            # id q1e3
```

- **Stages** are parts tagged `stage`, `objective`, `outcome` or `fails`. A part's name is true in another
  condition once it is reached, so stages compose without flags of their own.
- **`when`** is the condition that reaches it, over the story's facts, the quest's own facts and roles, other quests
  (`the_stranger.named`) and the host's queries. **`after`** orders stages for the journal and for analysis; it
  is not a gate unless the condition says so.
- **Reached is kept.** Once reached, a stage stays reached (its fact latches), unless it is tagged `live`: then it
  follows its condition, for "carry the lamp" kinds of objective that can be undone.
- **Outcomes end the quest; `fails` ends it failed.** A quest may have many outcomes, each a different ending. A
  quest ends when its first outcome or failure is reached; reaching two in one step is an error the checker rules out
  where it can and the runtime reports where it cannot.
- **Effects** under a stage are emitted when it is reached: rewards, changes to facts, actions. cairn applies none.
- **Journal entries** are a stage's lines, with stable ids, translated and voiced like dialogue.
- **Roles** are `ref` facts, opaque handles the host owns (an entity, an item, a place), declared with a kind and
  bound when the quest starts. **Instances:** a quest tagged `repeat` can run as many instances, each with its own
  roles and facts; others run once.
- **Activation** is tags on stages: `# active spawn_stranger · pin the_letter` keeps those keys in the active set
  while the stage is the quest's current one; `# keeps key` keeps one from that stage until the quest ends.
- **Starting** is a stage with no `after` whose condition holds, or the host's `start(quest, roles)`. A quest that
  starts itself is listed so the host can bind its roles first.

## State is facts

Everything cairn keeps is facts in riverrun's store: each instance's stages reached, current stage, roles, its own
facts and its status, in the scope the story declares for its quests. So
quests save, replicate, journal and restore exactly as everything else does: void-engine's record store holds them,
its delta stream replicates them, its journal replays them. cairn adds no store, no save format and no network
protocol.

- **A save survives a patch.** Stages are restored by name; a stage whose condition holds is reached on the first
  evaluation after loading, so a patch that fixes a quest's condition repairs old saves without a migration.
- **The active set and the journal are derived,** never saved: recomputed from the facts on load, so they cannot
  disagree with them.

## Evaluation: work follows change

The executor is data-oriented and incremental:

- **A dependency index**, built when the story loads: for every fact, the conditions that read it, as a compressed
  sparse array. Other quests' stages are facts too, so dependencies between quests are the same index.
- **A step** takes the facts that changed since the last step (riverrun's change stamps through a `Watcher`),
  gathers the conditions that read them, deduplicated by a bitset, and evaluates only those with riverrun's postfix
  evaluator. Stages reached in a step can make further conditions true; the step repeats over what they changed,
  to a fixed point, bounded by a named error (a cycle the checker missed cannot hang the host).
- **No allocation per step.** Instance state is structs of arrays indexed by distinct ids (aegis), the candidates a
  reused bitset, the output written into a caller's buffer.
- **Deadlines cost nothing while time passes.** A condition that compares a fact declared `(clock)` (a monotonic
  time the host advances: a day, an hour, seconds) against a value is indexed by when it can change, in a heap. The
  clock ticking wakes only the conditions whose moment has come, so a real-time game pays nothing per tick for its
  thousand timed quests, and a calendar game's day changing wakes only what that day decides.
- **Budgets.** A host may bound conditions evaluated per step and carry the rest to the next, for frame budgets; the
  result is the same as an unbounded step taken later.
- **Determinism.** No clock (time is a fact the host sets), no randomness, a fixed evaluation order (by id), so a
  server and a replay reach the same state from the same changes.

A step returns what happened: stages reached, quests started, ended and failed, effects to apply, and the active set's
changes (keys added and removed), each with its instance and roles.

## Checks when compiling

cairn's pass runs inside riverrun's check, with riverrun's diagnostics:

- every stage's condition typed; every name resolved; roles bound before they are read;
- `after` acyclic; dependencies between quests acyclic;
- **reachability:** every stage can be reached: something can set what its condition needs (a story effect, a
  `(game)` fact the host writes, another stage);
- **stuck quests:** a quest with a path where every outcome becomes impossible and no failure holds is reported with
  that path. Conditions are over finite enumerations, sets and booleans, so this is decidable for them; over ints
  and queries it is reported as unknown rather than guessed;
- outcomes that can be reached together;
- activation keys against the host's schema.

## Tools

cairn's model joins riverrun-studio's: quests as their own graph (stages, `after`, outcomes, the facts that drive
them, and the sections that set those facts), **why** (for a stage not reached: which term of its condition is
false, and what in the story or the game would make it true), and the timeline of a playthrough's fact changes and
the stages they reached. `weir` draws them in the terminal; void-engine's editor draws the same commands.

## The code, by layer

```
syntax    nothing: quests are riverrun's syntax
check     cairn's pass inside riverrun's check: stage kinds, roles, after, stuck quests   riverrun.check
compile   cairn's block in the compiled story: stages, conditions, dependency index       riverrun.story
run       the incremental executor over riverrun's facts                                  riverrun.facts, story
ffi       the C ABI beside riverrun's                                                     run
```

A game that runs quests links `run` beside riverrun's `run`; the checker and compiler stay at build time.

## What it needs from riverrun

- **Registered section kinds** with their tag schema, so `(quest)` sections are read and checked generically and
  handed to cairn's pass.
- **Extension blocks** in the compiled story: a named, versioned block a package owns (`cairn`), beside the graph,
  validated by its owner's reader.
- **A `ref` fact type:** an opaque 64-bit handle the host owns, declared with a kind (`ref of person`), compared and
  stored, never inspected. Any engine's entities, items and places reach stories through it.
- **`(clock)` facts:** an int the host only advances, which the checker and the evaluator may treat as monotonic.
- The change stamps and `Watcher` it already has.

## Packages

| package | for |
|---|---|
| riverrun | the language, the checker, the compiled format, facts, the evaluator |
| aegis | distinct ids for quests, stages, instances and roles; bounds as named errors |
| strand | the JSON dump of the quest graph and of a playthrough's timeline |
| shakedown | deterministic tests and replays |
| preflight, glint, bay | the gate |

## Napkin math

- **A large game:** 2,000 quests of 20 stages, 40,000 conditions of about six terms: some 240,000 terms, about 2 MB
  compiled with the dependency index.
- **A step** after a dialogue choice changes a handful of facts; each fact is read by a few dozen conditions; so a
  few hundred terms are evaluated, microseconds, however many quests are open.
- **State:** a few bytes per stage reached and per role; a hundred thousand instances of repeatable quests fit in a
  few megabytes of facts.

## Bounds

Stages per quest 256, roles per quest 16, steps to a fixed point 64, each a named error. Instances are counted per
store, not per game: a server keeps a store per player, party or region, so a persistent world's millions of
instances are many stores' thousands.

## Shapes it serves

- **A calendar game** (Persona's kind). The date and time slot are `(clock)` facts; a deadline is a failure
  (`fails when { day > may_5 and not heart_stolen }`); a bond's ranks are stages over its points and the free slots,
  each rank's scene a riverrun section; requests are repeatable quests. What the day offers is the active set.
- **A story-driven role-playing game** (a JRPG's main line and side quests, or one of many endings). Chapters are
  quests whose outcomes start the next; side quests read the main line's stages; endings are outcomes over
  everything the player did.
- **A procedural universe** (No Man's Sky's kind). Missions are templates whose roles the host binds to generated
  planets, ships and goods, as `ref`s; which template a board offers is a riverrun pool, chosen by specificity over
  the world's facts; journal lines show the roles through the host's queries (`{name(target)}`).
- **A persistent world** (Star Citizen's kind). The server runs cairn, the authority; facts live in stores per player,
  party and region, backed by the game's own database through the store interface; a world event is a region's quest
  whose players' contributions are facts in their own scopes; clients receive facts, never quest logic.
