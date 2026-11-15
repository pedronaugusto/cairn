# cairn's design

cairn runs quests: what a player is trying to do, how far they have got, what they found out, how it ended, and what
the world shows because of it. Quests are written in `.river` files and compiled by riverrun; their state is
riverrun's facts. cairn knows no engine and no game. This page is the design it is built to; what is built is marked
so.

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

```river
== the_stranger (quest)
  [title "Who was he?"] [scope player]
facts (player):
  stranger: ref of person   (role)     // given by the host when the quest starts
  asked: set of margaret, tom, danny

= noticed      when { met }
  [stage] [active spawn_stranger]
  A man nobody knows stood at the foot of the coffin. ^q1a9
= the_letter   when { found has letter }
  [objective] [after noticed] [active pin_letter]
  A letter signed "L.", from a city she never lived in. ^q1b2
= the_hands    when { said has gave }
  [objective] [optional] [after noticed]
  He said the hands were the same. ^q1c4
= named        when { the_letter and the_hands }
  [outcome] [after the_letter]
  [carried += his_name]
  He was {name(stranger)}, her son, from a life she didn't live. ^q1d7
= gone         when { hour >= 6 and not the_letter }
  [fails]
  He left before dawn. Nobody had his number. ^q1e3
```

- **Stages** are parts tagged `[stage]`, `[objective]`, `[outcome]` or `[fails]`, the tags in brackets under the
  part's heading, with the stage's effects after them (`[carried += his_name]`). A part's name is true in another
  condition once it is reached, so stages compose without flags of their own.
- **`when`** is the condition that reaches it, over the story's facts, the quest's own facts and roles, other quests
  (`the_stranger.named`) and the host's queries. **`after`** orders stages for the journal and for analysis; it
  is not a gate unless the condition says so.
- **Since a stage:** `since(stage, fact)` is how far an int fact has moved since the stage was reached (cairn
  records its value then; 0 before), so counting from acceptance needs no arithmetic in the language: `when {
  since(accepted, wolves_killed) >= 10 }`, and over a `(clock)` fact a relative deadline, `fails when {
  since(accepted, day) > 3 }`, which waits in the clock's heap as the clock itself does (riverrun's
  `Builtin.moves`).
- **Order:** `before(a, b)` holds once stage `a` was reached while `b` was not; reached in the same step, neither
  came first. cairn latches it when `a` is reached, so "you told her before he found out" needs no arithmetic.
- **Shared rules.** A `(quest rules)` section's stages are inherited by every quest of its module (or of any, from
  the root) that has every role the stage reads, of the same kind: `= abandoned when { dead(giver) }`, `[fails]`
  under it, written once for every quest with a `giver`. Its roles are its own `(role)` facts, read as each quest's.
  A stage that reads no role is inherited by the quests that follow the section by tag, `[follows everyone]`. A
  quest that writes a stage of the same name says otherwise, and keeps its own. Shared stages read roles and the story's
  facts; `since` and `before` count from a quest's own. *Protects:* a thousand quests that do not each restate what
  the world means.
- **Reached is kept.** Once reached, a stage stays reached (its fact latches), unless it is tagged `live`: then it
  follows its condition, for "carry the lamp" kinds of objective that can be undone.
- **Outcomes end the quest; `fails` ends it failed.** A quest may have many outcomes, each a different ending. A
  quest ends when its first outcome or failure is reached; reaching two in one step is an error the checker rules out
  where it can and the runtime reports where it cannot.
- **Queries in quests declare what invalidates them.** A host query reads state riverrun cannot see (an
  inventory, a position), so its answer cannot be watched. A query used in a quest condition is declared with the
  stamp of its state, keyed by its arguments where that is finer: `count(kind: ref of item_kind) -> int (reads
  stock(kind))`. The host bumps `stock(wolf_pelt)` when pelts come or go, and only the conditions filed under
  (`count`, `wolf_pelt`) wake: a pickup in a game of ten thousand item kinds touches a handful. A query without a
  stamp is refused in quests by the checker. *Protects:* incremental evaluation with no condition polled every
  step, and no copy of the host's state in facts.
- **Effects** under a stage are emitted when it is reached: rewards, changes to facts, actions. cairn applies none.
- **Journal entries** are a stage's lines, with stable ids, translated and voiced like dialogue.
- **A quest's own facts** are riverrun's: a `facts:` block under its heading, named within it (`asked` inside,
  `the_stranger.asked` outside), kept in the scope its `[scope …]` names, where its stages are, so they save together.
- **Roles** are its own facts marked `(role)`, usually `ref`s, opaque handles the host owns (an entity, an item, a
  place), given when the quest starts and never set by the story; at most 16. Its conditions read them as constants,
  so `dead(giver)` wakes when that giver dies and no other. **Instances:** a quest tagged `repeat` can run as many
  instances, each kept per a thing of the quest's own kind (`ref of bounty`), numbered by cairn from 1: every fact
  it declares is kept per instance, read inside it for the one being evaluated, `bounty.tracked(lead)` from outside.
  Others run once.
- **Activation** is tags on stages: `[active spawn_stranger, pin_letter]` keeps those keys in the active set while
  the stage is the quest's current one, the stage reached last (falling back to the last written still reached when
  a live one leaves); `[keeps key]` keeps one from that stage until the quest ends. A key is one of the host's
  things of the kind `activation`, checked against its manifest where it lists them and resolved to its handle at
  load.
- **Starting** is a stage with no `after` whose condition holds, or the host's `start(quest, roles)`; `[start host]`
  leaves it to the host alone, and a repeat quest is only ever started by the host. A quest that starts itself and
  has roles is listed (`unbound`) so the host can give them first (`bind`); until then it is not watched.

Built: all of the above.

## State is facts

Everything cairn keeps is facts in riverrun's store: each instance's stages reached, current stage, roles, its own
facts and its status, in the scope the story declares for its quests. So
quests save, replicate, journal and restore exactly as everything else does: an engine's record store holds them,
its delta stream replicates them, its journal replays them. cairn adds no store, no save format and no network
protocol.

- **A save survives a patch.** Stages are restored by name; a stage whose condition holds is reached on the first
  evaluation after loading, so a patch that fixes a quest's condition repairs old saves without a migration. A
  current stage the patch took away falls back to the last stage written that is reached.
- **The active set and the journal are derived,** never saved: recomputed from the facts on load (`restored`), so
  they cannot disagree with them.
- What cairn keeps for itself is named with `@` within the quest (`the_stranger.@status`, `@current`,
  `@since.accepted.day`, `bounty.@count`), so no writer names it and a snapshot saves it by name.

Built.

## Evaluation: work follows change

riverrun's evaluation layer, which runs `(rules)` sections, is cairn's engine too: a quest is rules with quest
meaning on top (stages that latch, outcomes, the journal, roles, instances, the active set). The evaluator, written
once in riverrun and shared, is data-oriented and incremental:

- **A dependency index**: for every fact, the stages that read it, a compressed sparse array in cairn's block for
  tools (`readers`), and riverrun's `Watch` filing each condition when it is watched, under the facts and keys it
  reads, the stamps it asks and the clocks it compares. Other quests' stages are facts too, so dependencies between
  quests are the same index.
- **What is watched** is what can still change: an active instance's stages not yet reached and its live ones, each
  watched for its instance (`this`) with its roles; a stage reached stops being watched, and an instance that ends
  stops costing anything. A quest that starts itself has only its first stages watched until it does.
- **A step** takes the marks since the last from the store's log (riverrun's `Changes`, each a fact and the key that
  changed), gathers the conditions filed there, deduplicated by a bitset, and evaluates only those with riverrun's
  postfix evaluator. Stages reached in a step can make further conditions true; the step repeats over what they
  changed, to a fixed point, bounded by a named error (a cycle the checker missed cannot hang the host). cairn
  writes its own facts as it reaches stages; a stage's effects are emitted, and seen at the next step.
- **No allocation per step** once its buffers have grown: what is watched is lists and a bitset kept between steps,
  and what a step says it says in buffers it keeps, valid until the next, as riverrun's react layer does.
- **Time passing costs nothing.** A comparison against a `(clock)` fact (one the host only advances) is indexed
  by the value at which it flips, in a heap per clock, not by the fact changing; a clock moving wakes only the
  conditions whose moment has come, so a real-time game pays nothing per tick for its thousand timed quests. Facts
  derived from a clock that change rarely (a day, a slot) are ordinary facts.
- **Budgets.** A host may bound conditions evaluated per step and carry the rest to the next, for frame budgets; the
  result is the same as an unbounded step taken later.
- **Determinism.** No clock (time is a fact the host sets), no randomness, a fixed evaluation order (by id), so a
  server and a replay reach the same state from the same changes.

A step returns what happened: stages reached, quests started, ended and failed, effects to apply, and the active set's
changes (keys added and removed), each with its instance, whose roles `role` reads.

```
Quests.init(gpa, story, store, host, owners, options) · restored() · deinit()
start(quest, roles) → instance · bind(quest, roles) · unbound(out) · bump(family, keyed)
step() → events: started · reached(stage, effects) · left(stage) · ended(stage, failed) · activated · deactivated
status · reached · current · role · started · activeSet · journal(instance, out) · lines · say · readers
```

Built, with the named errors `TwoEndings`, `NoFixedPoint`, `TooManyInstances`, `WrongRoles`, `AlreadyStarted` and
`HostNotBound`.

## Played without the game

`riverrun play` runs a story's quests as a game does: `cairn.package` carries cairn's runtime for riverrun's
tools (`running`, in `src/front/running.zig`), which starts `Quests` over the played story's facts, steps it
whenever they change, and says what each step did: `! started the_stranger`, `! reached the_stranger.noticed`
with the stage's journal lines and its effects (which the play applies, as a game would), `! left`, `! ended` or
`! failed` at the ending stage, `! active` and `! inactive` for its activation keys. Its builtins answer the
story's own `since` and `before`, and a query's answer the player sets is bumped as the game bumps its stamp. A
quest that starts itself and has roles is given what the game would give it, a stand-in thing for each role, named
for the role (`stranger`), which the player names in `:set name(stranger) = "Tom"`. What cairn asks while it works
out a news (a journal line's `{name(target)}`) is told under that news. An error in a stage's condition or effects
is placed where it is written.

The game's calls into cairn that change what the story tells are offered to the player as the play's commands,
which `:help` lists with each quest of the story and its roles:

- `:start QUEST ROLE=THING…` is the game's `start`: any quest, with its roles, a thing of the role's kind each (the
  story's thing of that name, else one of the game's the play stands in for); a repeat quest's next instance each
  time (`! started bounty(2)`). Refused where the quest is not there, a role is missing, given none or a thing of
  another kind, or a quest that runs once has started (`delivery` has started already).
- `:bind QUEST ROLE=THING…` is the game's `bind`, for a quest that starts itself and has roles: its roles given
  before it starts (in place of the stand-ins), refused once it has started.

```
> :start bounty target=wolf
! started bounty(1)
! reached bounty(1).posted
  A price on .
  ? name(wolf) = "" (not set)
! active pin_target
```

Before the story starts, `riverrun play --call 'start delivery giver=hilde'`. The rest of cairn's API a game calls
changes nothing a story tells, or is the play's own already: `step` (the play steps it), `bump` (`:set` of a
query's answer bumps it), `restored` (going back is the play's `:back`), and what reads (`status`, `journal`,
`activeSet`…), which the news already tells.

Built.

## How the host answers

A quest reaches the game's state through riverrun's host binding, which cairn uses as it is:

1. **Declared in the story.** `count(kind: ref of item_kind) -> int (reads stock(kind))` is in the game's
   vocabulary; the compiled story keeps its name, its signature and its stamp.
2. **Bound at load.** The game binds an implementation to each extern by name, checked: a Zig game passes a struct
   of functions, reflected into a table indexed by extern id; a C, C++ or C# game binds by name with a function
   pointer. A story's `ref` literals (`wolf_pelt`) are stable text ids the game resolves to its own handles once,
   at load, against the manifest the checker also read, so a typo fails at build.
3. **Called with a context.** A condition's evaluation calls `count(wolf_pelt)` through the table with the instance
   and the scope's owner, so a server knows whose inventory to read.
4. **Woken by stamps.** When an instance starts, its conditions are filed under the stamps their queries read, with
   the arguments bound (`stock(wolf_pelt)`). The game's inventory bumps that stamp when pelts come or go, through a
   small adapter it writes once, or, on an engine whose fact store is its own records, through the engine's change
   stream; the next step evaluates only the conditions filed there.

```
.river ── compile ──▶ extern table: count(ref of item_kind) -> int, reads stock(kind)
                         │ load: bind count → inventory.count · resolve "wolf_pelt" → handle
tick:  inventory changes ──▶ stamp(stock, wolf_pelt)
       cairn.step ──▶ conditions under (stock, wolf_pelt) ──▶ count(ctx, wolf_pelt) = 7 ──▶ 7 of 10
```

## One language

cairn has no language of its own. Quests are written in `.river` beside the dialogue that drives them: riverrun's
reader, checker, ids, modules, translation and tools serve both, and a writer learns one thing. cairn adds
vocabulary, not grammar: the `quest` and `quest rules` kinds, their tag schema (`stage`, `objective`, `outcome`,
`fails`, `live`, `optional`, `after`, `active`, `keeps`; on a quest `title`, `scope`, `repeat`, `start` and
`follows`) and the builtins `since` and `before`, registered with riverrun's compiler as one package,
`cairn.package`. What a quest needed that no package should own became riverrun's: a section's own facts and its
`(role)`s, a section kept per thing, and a condition watched for one thing with its roles.

Built.

## Checks when compiling

cairn's pass runs inside riverrun's check, with riverrun's diagnostics:

- every stage's condition typed and every name resolved (riverrun's); each part one kind, an ending never `live`,
  `optional` only on an objective, a condition on every stage, a body of lines and effects; a quest's facts in the
  scope of its stages; an inherited role of the kind the rules read; roles given before a quest that starts itself
  is watched;
- `after` naming the quest's stages, and acyclic;
- **dependencies that go round through a live stage** refused: stages that read each other round with a live one
  among them could keep changing each other for ever, while latching ones settle, so only the first are refused
  (the design first asked all dependencies between quests to be acyclic, which refuses quests that inform each
  other and settle);
- **reachability:** a stage nothing the story does can make reachable is warned of;
- **stuck quests:** a state the story can reach from which no outcome or failure can ever be is reported with the
  way there (`once fate is dead`). Conditions are formulas over booleans, a `one of` holding a value and a set
  holding an item, each moving only as the story's effects can move it (the game's any way); ints, queries and
  builtins are free atoms, so what depends on them is unknown and never reported; past 64 atoms or 32,768 states
  a quest is left unknown;
- **endings that can hold together**, refused where neither reads a free atom; the runtime refuses the rest
  (`TwoEndings`);
- activation keys against the host's manifest of things of the kind `activation`;
- a query without a stamp in a stage's condition (riverrun's check of every watched condition).

Built.

## Tools

cairn's model joins riverrun-studio's: quests as their own graph (stages, `after`, outcomes, the facts that drive
them, and the sections that set those facts), **why** (for a stage not reached: which term of its condition is
false, and what in the story or the game would make it true), and the timeline of a playthrough's fact changes and
the stages they reached. A terminal tool and an engine's editor can draw them from the same commands.

Not built. What they stand on is: `cairn-compiler`'s `read` (a checked story's quests), the block's dependency
index (`Quests.readers`), and the events a step returns.

## The code, by layer

```
syntax    nothing: quests are riverrun's syntax                                           built
check     cairn's pass inside riverrun's check: stage kinds, roles, after, stuck quests   riverrun.check · built
compile   cairn's block in the compiled story: stages, conditions, dependency index       riverrun.story · built
run       the incremental executor over riverrun's facts                                  riverrun.react · built
ffi       the C ABI beside riverrun's                                                     run
```

The layers are two modules, as tide's are. `cairn`, the runtime, is `src/cairn/` (the block, its loader, `Quests`
and the active set) on aegis and riverrun's runtime; `cairn-compiler` is `src/front/` (the vocabulary, the
declarations, the judges, the reader of a checked story, the analysis and the pass), from `compiler(dep)` in
cairn's `build.zig`, on the one riverrun a story's build stands on. A game that runs quests links `cairn` beside
riverrun's runtime; the checker and compiler stay at build time.

The C ABI waits for riverrun's, which is not built: cairn's would be beside it, over the same handles. The seam is
`Quests`, whose calls take and give plain ids (`QuestId`, `StageId`, an instance's 64-bit key), values riverrun's C
ABI will carry, and slices valid until the next step, which a C caller copies as it reads them.

## What it needs from riverrun

- **Registered section kinds** with their tag schema, so `(quest)` sections are read and checked generically and
  handed to cairn's pass; their facts declared within them, seeing the story (`Kind.declare`), and kept per thing
  where they repeat (`Kind.per`); tag values judged where they are written.
- **A section's own facts and roles:** `facts:` under its heading, `(role)` among them.
- **Extension blocks** in the compiled story: a named, versioned block a package owns (`cairn`), beside the graph,
  validated by its owner's reader, its conditions checked as riverrun's are (`Story.condition`).
- **A `ref` fact type:** an opaque 64-bit handle the host owns, declared with a kind (`ref of person`), compared and
  stored, never inspected. Any engine's entities, items and places reach stories through it.
- **`(clock)` facts:** an int the host only advances, which the checker and the evaluator may treat as monotonic,
  and builtins whose answer moves with one. Who advances them is the host's choice; tide is one.
- **`Watch`** watching a condition for a thing with its roles, letting it go, and reading the store's log of marks.
- Stories of 65,535 facts, and no visit count for a section only a package runs.

All built in riverrun.

## Packages

| package | for |
|---|---|
| riverrun | the language, the checker, the compiled format, facts, the evaluator |
| aegis | distinct ids for quests, stages and instances |
| strand | the JSON dump of the quest graph and of a playthrough's timeline, with the tools |
| shakedown | deterministic tests and the benchmark |
| preflight, glint, bay | the gate |

## Napkin math

- **A large game:** 2,000 quests of 20 stages, 40,000 conditions of about six terms: some 240,000 terms, about 2 MB
  compiled with the dependency index.
- **A step** after a dialogue choice changes a handful of facts; each fact is read by a few dozen conditions; so a
  few hundred terms are evaluated, microseconds, however many quests are open.
- **State:** a few bytes per stage reached and per role; a hundred thousand instances of repeatable quests fit in a
  few megabytes of facts.

Measured (`bench/quests.zig`, an Apple M3, ReleaseFast): 2,000 quests of 20 stages, each condition about ten terms
over the stage before, two of 1,500 facts and the count of one of 10,000 item kinds, every quest started. The
terms are 1.5 MB and cairn's block, its stages and the dependency index, 1.5 MB; the whole graph is 10 MB, the rest
riverrun's record of each stage as a section with its tags. A step after a choice of five facts evaluates 271
conditions in 14 µs; after a pickup, 4 conditions in 0.6 µs; after nothing, 0.3 µs. The story compiles in 0.21 s
and loads with every quest started in 13 ms. A hundred thousand instances of a repeat quest take their first step
in 36 ms and all end in one step in 73 ms; ended, they are 500,000 values of facts, some 30 MB in riverrun's
default store, which keeps each in 56 bytes, so the napkin's few megabytes want a store of the host's that packs
them.

## Time without a dependency

cairn needs of time only that a `(clock)` fact never goes back. It does not use tide: any clock a host keeps (tide's,
an engine's sim clock, a server's) serves, and a calendar's days and slots reach quests as ordinary facts. The two
meet in facts, so a game can take either alone.

## Bounds

Stages per quest 256, roles per quest 16, steps to a fixed point 64, instances run at once 16,777,216 and keys a
quest's fact holds 1,048,576 (riverrun's), each a named error, and a story's facts 65,535 (riverrun's). Instances
are counted per store, not per game: a server keeps a store per player, party or region, so a persistent world's
millions of instances are many stores' thousands.

## Decided while building

- **A quest's own facts and roles are riverrun's.** The design first wrote `role stranger: ref of person` as a
  quest's own line, which is grammar no other section could use: a section's own `facts:` and `(role)` among them
  serve any section, and a quest is one.
- **An activation key is a word, one of the host's things.** `pin the_letter` named a stage beside a key; a key
  with an argument is a second language. A key is a thing of the kind `activation`, checked against the manifest
  and resolved to the host's handle as every thing is, and the instance's roles stand in for arguments.
- **A repeat quest is kept per a thing of its own kind,** numbered by cairn, because riverrun's facts kept per
  thing are how state scales, and a host that has ids of its own gives them as roles.
- **Only dependencies that go round through a live stage are refused.** Latching stages that read each other
  settle, and quests that inform each other are common; a live one in the round could change for ever.
- **A step says what happened in buffers it keeps,** valid until the next, as riverrun's react layer does, rather
  than a caller's: one rule for the family, and still nothing allocated once they have grown.
- **The journal is in the order written,** not the order reached: cairn keeps the stage reached last, not the
  order of all.

## Shapes it serves

- **A calendar game** (Persona's kind). The date and time slot are facts of the game's calendar (tide's, or the
  host's own); a deadline is a failure
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
- **An open world of people who can die** (Baldur's Gate 3's, The Witcher 3's, Red Dead Redemption 2's kind). A
  giver's death fails every quest they gave through one shared stage, `abandoned when { dead(giver) }`, and a
  quest that says otherwise keeps its own (a debt settled by it); a quest that fails when another moves on reads
  that quest's stage; honour is a bounded int that rules drift and quests read and change, `honor >= 20` opening a
  stranger's mission; a contract board is a repeat quest whose target is a role.

What does not serve them yet: the tools (the graph, why, the timeline) are not built; a scene told for one
instance of a repeat quest writes its facts with the instance's key (`bounty.tracked(lead)`), since riverrun's
sessions are not run for a thing; and `since` and `before` count only from a quest's own stages, not a shared one's.
