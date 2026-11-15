# 10. Quests

On the far bank Otto has an errand for the player: a card of needles up to Mrs Miller at the mill, and the three
coins she owes him brought back. The player may do it, do half of it, or lose the needles in the mud chasing a pig.
The game keeps a journal of what the player set out to do, how far they have got and how it ended, and shows the
world changing with it: that is a quest.

```river
== errand (quest)
  [title "Needles for the mill"] [scope player]
= taken        when { took_needles }
  [stage] [active mill_marked]
  Otto gave you a card of needles for Mrs Miller at the mill, and wants what she owes him.
= delivered    when { taken and carrying hasnt needles and not needles_lost }
  [objective] [after taken]
  You left the needles at the mill.
= paid         when { miller_paid }
  [objective] [after delivered]
  Mrs Miller paid what she owed.
= done         when { delivered and paid and carrying hasnt money }
  [outcome] [after paid]
  [trust += 1]
  Otto has his money, and calls you a friend.
= lost         when { needles_lost and not delivered }
  [fails]
  Otto's needles went into the mud, and the pig after them.
```

That is the quest of `stories/10/errand.river`; the scenes that move it, Otto's stall and Mrs Miller's door, are
[below](#the-scenes-that-move-it).

Quests are run by cairn, a package the game builds in beside riverrun, and this chapter is cairn's: it lives in
cairn's repository, beside the stories it shows. Everything else in it is the language of
[the manual](https://github.com/pedronaugusto/riverrun/blob/main/docs/manual/README.md), used as the earlier chapters
teach it.

## A quest

`== errand (quest)` is a section of the kind `quest`. Nothing goes to it with `->`, and it is never said as a scene
is: it is the quest's page in the game's journal, and the story's facts move it on. Its tags stand under its
heading:

- `[title "Needles for the mill"]`: what the journal calls it. A player reads it, so it is translated as a line is.
- `[scope player]`: the scope its stages are kept in, so the quest is saved with the player's facts
  ([chapter 3](https://github.com/pedronaugusto/riverrun/blob/main/docs/manual/03-remembering.md)).

Its parts are its **stages**, and the lines under a stage are its **journal**: what the game shows when the stage
is reached.

## Stages

```river
= taken        when { took_needles }
  [stage] [active mill_marked]
  Otto gave you a card of needles for Mrs Miller at the mill, and wants what she owes him.
```

A stage is a part with a condition after `when`, and a tag that says which of four kinds it is:

- `[stage]`: a step on the way, the errand taken on.
- `[objective]`: something the player is to do, as the journal lists it: the needles left at the mill, the money
  got. `[optional]` marks one the player may leave undone.
- `[outcome]`: an ending. Reaching it ends the quest; a quest may have several, each a different ending.
- `[fails]`: an ending in failure.

Every stage has one kind and a condition. Under its tags go its journal's lines and what reaching it does, and
nothing else.

## What moves a quest on

A stage is reached when its condition holds, and stays reached. Nothing in the story says "go on to the next
stage": the scenes set facts, as any scene does, and the quest follows. Otto's stall sets `took_needles`, and
`taken` is reached; the needles leave the player's hands at the mill, and `delivered` is.

```river
= delivered    when { taken and carrying hasnt needles and not needles_lost }
  [objective] [after taken]
  You left the needles at the mill.
```

A stage's name is a fact, true once it is reached, so a condition reads stages as it reads any fact: `taken and
carrying hasnt needles` is the needles gone after the errand was taken on. Outside its quest a stage is named with
the quest's name before it, `errand.delivered`, and the story's scenes read it so
([below](#the-scenes-that-move-it)).

`[after taken]` says the stage comes after `taken`: it orders the journal, and what the checker works out about the
quest. It does not keep the stage from being reached; only its condition does that, so a stage that must wait for
another says so in its condition, as `delivered` does.

A stage tagged `[live]` holds only while its condition does, and is left when it stops: "keep the lamp lit", which
the player can undo. An ending is never `live`.

## What reaching a stage does

```river
= done         when { delivered and paid and carrying hasnt money }
  [outcome] [after paid]
  [trust += 1]
  Otto has his money, and calls you a friend.
```

The brackets under a stage's kind are what reaching it does: effects, as in
[chapter 4](https://github.com/pedronaugusto/riverrun/blob/main/docs/manual/04-telling-the-game.md). Here Otto
thinks better of the player.

`[active mill_marked]`, on `taken`, is something the world shows for the quest while that stage is its current one,
the stage it reached last: the game marks the mill on its map until `delivered` is reached. `mill_marked` is one of
the game's things, of the kind `activation`, and the game's vocabulary lists them, so a key the game does not have
is a mistake the checker finds. A mark on a map, a person standing at a door, a gate left open: what each key does
is the game's. `[keeps key]` keeps one from its stage until the quest ends.

## The scenes that move it

```river
== stall
OTTO: Needles, thread, buttons!
{ errand.done } OTTO: There's my friend.
- (ask)
* Ask if he needs anything.
  OTTO: Mrs Miller at the mill. A card of needles, and the three she owes me.
  [took_needles = true] [carrying += needles]
  -> ask
* { carrying has money } Give him Mrs Miller's money.
  [carrying -= money]
  OTTO: Every penny. Who'd have thought it.
  -> ask
* Go after the pig.
  The pig gets away through the crowd.
  { carrying has needles }
    And Otto's needles are somewhere in the mud.
    [carrying -= needles] [needles_lost = true]
  -> ask
+ Walk up to the mill.
  -> mill
* Go back to the ferry.
  -> end
```

```river
== mill
A door in the dark, and flour on the step.
MILLER: Who's that, at this hour?
- (door)
* { carrying has needles } Hand her the needles.
  [carrying -= needles]
  MILLER: From Otto. And he'll want paying, I suppose.
  -> door
* { errand.delivered and not miller_paid } Ask for what she owes Otto.
  [miller_paid = true] [carrying += money]
  MILLER: Three. Tell him not to spend it all at once.
  -> door
+ Go back down to the fair.
  -> stall
```

`{ errand.done }` and `{ errand.delivered and not miller_paid }` read the quest's stages: Otto greets a friend, and
Mrs Miller is asked for the money once she has the needles. The quest and the scenes read the same facts, and
neither calls the other.

## Playing a quest

`riverrun play` runs a story's quests as the game does, and says what each did as it happens:

```console
$ riverrun play -i 1 -i 3 -i 1 -i 1 -i 1 -i 1 -i 2 -i 1 -i 3 errand.river
== fair
Lamps on poles, mud underfoot, and somebody's pig loose among the stalls.
== stall
OTTO: Needles, thread, buttons!
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> 1
OTTO: Mrs Miller at the mill. A card of needles, and the three she owes me.
[took_needles = true] [carrying += needles]
! started errand
! reached errand.taken
  Otto gave you a card of needles for Mrs Miller at the mill, and wants what she owes him.
! active mill_marked for errand
* 1 (closed) Give him Mrs Miller's money.
* 2 Go after the pig.
* 3 Walk up to the mill.
* 4 Go back to the ferry.
> 3
== mill
A door in the dark, and flour on the step.
MILLER: Who's that, at this hour?
* 1 Hand her the needles.
* 2 (closed) Ask for what she owes Otto.
* 3 Go back down to the fair.
> 1
[carrying -= needles]
! reached errand.delivered
  You left the needles at the mill.
! inactive mill_marked for errand
MILLER: From Otto. And he'll want paying, I suppose.
* 1 Ask for what she owes Otto.
* 2 Go back down to the fair.
> 1
[miller_paid = true] [carrying += money]
! reached errand.paid
  Mrs Miller paid what she owed.
MILLER: Three. Tell him not to spend it all at once.
* 1 Go back down to the fair.
> 1
== stall
OTTO: Needles, thread, buttons!
* 1 Give him Mrs Miller's money.
* 2 Go after the pig.
* 3 Walk up to the mill.
* 4 Go back to the ferry.
> 1
[carrying -= money]
! reached errand.done
  Otto has his money, and calls you a friend.
  [trust += 1]
! ended errand.done
OTTO: Every penny. Who'd have thought it.
* 1 Go after the pig.
* 2 Walk up to the mill.
* 3 Go back to the ferry.
> 2
== mill
A door in the dark, and flour on the step.
MILLER: Who's that, at this hour?
* 1 Go back down to the fair.
> 1
== stall
OTTO: Needles, thread, buttons!
OTTO: There's my friend.
* 1 Go after the pig.
* 2 Walk up to the mill.
* 3 Go back to the ferry.
> 3
-> end
```

A row that begins with `!` is the quest's **news**, told after the row that caused it:

- `! started errand`: the quest has started. A stage with no `after` whose condition holds starts it; until then
  the journal has nothing of it.
- `! reached errand.taken`: a stage reached, with its journal's lines under it and what it does. The play applies
  an effect as the game would: `[trust += 1]` changes `trust`.
- `! active mill_marked for errand` and `! inactive mill_marked for errand`: a key the world shows, and for which
  quest, given and taken back as the quest's current stage changes.
- `! ended errand.done`: the quest has ended, at an outcome.

`OTTO: There's my friend.` is said on the way back to the stall, once the quest has ended.

## How a quest ends

A quest ends at the first outcome or failure it reaches. In this play the needles go into the mud:

```console
$ riverrun play -i 1 -i 2 -i 3 errand.river
== fair
Lamps on poles, mud underfoot, and somebody's pig loose among the stalls.
== stall
OTTO: Needles, thread, buttons!
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> 1
OTTO: Mrs Miller at the mill. A card of needles, and the three she owes me.
[took_needles = true] [carrying += needles]
! started errand
! reached errand.taken
  Otto gave you a card of needles for Mrs Miller at the mill, and wants what she owes him.
! active mill_marked for errand
* 1 (closed) Give him Mrs Miller's money.
* 2 Go after the pig.
* 3 Walk up to the mill.
* 4 Go back to the ferry.
> 2
The pig gets away through the crowd.
And Otto's needles are somewhere in the mud.
[carrying -= needles] [needles_lost = true]
! reached errand.lost
  Otto's needles went into the mud, and the pig after them.
! failed errand.lost
! inactive mill_marked for errand
* 1 (closed) Give him Mrs Miller's money.
* 2 Walk up to the mill.
* 3 Go back to the ferry.
> 3
-> end
```

`! failed errand.lost` is the failure: the quest is over, and the mark on the mill goes with it. A quest ends once,
so two endings that can hold at the same time are a mistake. `lost` holds only while the needles are not
delivered, and `done` needs them delivered, so the two never hold together.

Write a failure for every way a quest can be lost. Without one for the needles in the mud, the errand would stay
open for ever, waiting for needles that are gone: the oldest bug a quest has, and the checker finds it
([below](#when-the-checker-says-no)).

## Roles

Someone in the crowd at the fair has the player's purse. Who it is, the game decides: one of the people it has
walking about. The story writes the quest the same whoever it is.

```river
== cutpurse (quest)
  [title "A light hand"] [scope player]
facts (player):
  thief: ref of person   (role)      // someone in the crowd: the game says who
= robbed       when { purse_gone }
  [stage] [active watch_out]
  Somebody in the crowd has had your purse.
= got_back     when { caught(thief) }
  [outcome] [after robbed]
  The watch has {name(thief)}, and you have your purse.
= away         when { hour >= shuts_at and not caught(thief) }
  [fails]
  The fair has shut, and whoever it was has gone with it.
```

That is in `stories/10/fair.river`, the errand's story with two quests more and the scenes that move them.

A quest declares facts of its own under its heading, in the scope its stages are kept in, and named within it:
`thief` inside the quest, `cutpurse.thief` to the rest of the story. `(role)` marks one the game gives: one of its
things, here a `ref of person`, which the story reads and never sets. `caught(thief)` asks whether the watch has
hold of whoever it is, and `{name(thief)}` says their name, which the game answers
([chapter 7](https://github.com/pedronaugusto/riverrun/blob/main/docs/manual/07-the-games-vocabulary.md)).

The game gives a quest its roles when it starts it or, for a quest that starts itself as this one does, before it
starts: the game's `bind`. In a play `:bind` gives them, and until it does, each role is a stand-in, a thing the play
makes up and names after the role:

```console
$ riverrun play -i ':bind cutpurse thief=pip' -i ':facts cutpurse.thief' -i ':set name(pip) = "Pip"' -i 3 -i ':set caught(pip) = true' -i 4 fair.river
! roles cutpurse
  thief = thief, standing in for the game's
== fair
Lamps on poles, mud underfoot, and somebody's pig loose among the stalls.
== stall
OTTO: Needles, thread, buttons!
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> :bind cutpurse thief=pip
! roles cutpurse
  thief = pip
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> :facts cutpurse.thief
  cutpurse.thief = pip
> :set name(pip) = "Pip"
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> 3
The pig gets away through the crowd. So does whoever had a hand in your coat.
[purse_gone = true]
! started cutpurse
! reached cutpurse.robbed
  Somebody in the crowd has had your purse.
! active watch_out for cutpurse
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Walk up to the mill.
* 4 Go back to the ferry.
> :set caught(pip) = true
! reached cutpurse.got_back
  The watch has Pip, and you have your purse.
  ? name(pip) = "Pip"
! ended cutpurse.got_back
! inactive watch_out for cutpurse
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Walk up to the mill.
* 4 Go back to the ferry.
> 4
-> end
```

`! roles cutpurse` before the story starts is the stand-in: the thief is `thief`, nobody the game knows.
`:bind cutpurse thief=pip` gives the role `pip`, a person the story never names: a thing named in a command that the
story does not name is one of the game's, and the play stands in for it. The quest's news says it has its roles
again, `! roles cutpurse` with `thief = pip` under it, and `:facts cutpurse.thief` shows the same. From then on `pip` is a thing like
any other: `:set name(pip) = "Pip"` answers the query for them, and `:set caught(pip) = true` is the watch catching
them. Once a quest has started its roles are given, and `:bind` is refused.

## Quests the game starts

Otto gives the player parcels to carry, one at a time, each for somebody at the fair. The game starts a quest for
each, and says whom it is for:

```river
== parcel (quest)
  [repeat] [title "A parcel to carry"] [scope player]
facts (player):
  to: ref of person   (role)         // who it is for: the game says, each time
= given        when { true }
  [stage] [active parcel_marked]
  A parcel from Otto's stall, for {name(to)}.
= handed_over  when { handed(to) }
  [outcome] [after given]
  [trust += 1]
  The parcel is with {name(to)}.
= late         when { since(given, hour) > 2 and not handed(to) }
  [fails]
  Nobody came for the parcel. Otto has it back.
```

A quest the game starts is started with its roles, a thing for each: the game's `start`. `[repeat]` makes a quest
the game starts as often as it likes. Each start is an **instance**, numbered from 1, `parcel(1)`, `parcel(2)`,
with its own facts, so each parcel has its own `to` and reaches its own stages. A repeat quest is only ever started
by the game. A quest that runs once may be left to the game alone with `[start host]`, and then it never starts
itself.

In a play, `:start QUEST ROLE=THING…` is the game's `start`, and `--call 'start QUEST ROLE=THING…'` makes the same
call before the story starts. `:help` lists every quest of the story with the roles each takes:

```console
$ riverrun play -i :help fair.river
! roles cutpurse
  thief = thief, standing in for the game's
== fair
Lamps on poles, mud underfoot, and somebody's pig loose among the stalls.
== stall
OTTO: Needles, thread, buttons!
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> :help
  N                         take the choice numbered N
  VALUE                     the outcome an action waits for: true, 3, a value of its list, a thing, "words"
  :set FACT = VALUE         set a fact; += and -= add to a set or an int, or take from it
  :set FACT(KEY) = VALUE    a fact kept per thing, for one thing
  :set QUERY(ARGS) = VALUE  what the game answers a query with, from now on
  :wait N [CLOCK]           move a clock on N
  :facts [FACT ...]         the facts not at the value they start at, or those named
  :back                     back one input
  :restart                  from the start again
  :quit                     stop playing
  :start QUEST              the game starts a quest, its roles given (a repeat quest's next instance) (cairn)
      :start errand
      :start cutpurse thief=PERSON
      :start parcel to=PERSON
  :bind QUEST               the game gives a quest that starts itself its roles, before it starts (cairn)
      :bind cutpurse thief=PERSON
```

`:start` and `:bind` are cairn's, marked `(cairn)`: a package offers the game's calls into it as the play's commands,
and `:help` lists them after the play's own. `:start errand` is there too: the game may start any quest, even one
that would start itself. A command that does not fit the story is refused, and says why:

```console
$ riverrun play -i ':start parcel' fair.river
! roles cutpurse
  thief = thief, standing in for the game's
== fair
Lamps on poles, mud underfoot, and somebody's pig loose among the stalls.
== stall
OTTO: Needles, thread, buttons!
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
riverrun: error: the input `:start parcel`: :start parcel takes to=PERSON: `to` is missing
```

## Counting from a stage

`late` is reached when `since(given, hour) > 2`. `since(stage, fact)` is how far an int fact has moved since the
stage was reached, and 0 before it is. Over the fair's clock, `hour`, it is how long since the parcel was given:
two hours, and the parcel fails. `before(a, b)` holds once stage `a` was reached while `b` was not, for "you told
her before he found out". Both count from the quest's own stages.

## Rules every quest shares

```river
// how a quest to find someone at the fair fails: every quest with a `to` has it
== errands (quest rules)
facts (player):
  to: ref of person   (role)
= gone_home    when { went_home(to) and not handed(to) }
  [fails]
  Too late: {name(to)} has gone home.
```

A `(quest rules)` section's stages belong to no quest of their own. Every quest that has every role a stage reads,
of the same kind, inherits it: `gone_home` reads `to`, so `parcel` has it, and so would any other quest with someone
`to` find. Written once, it fails every such quest when the person goes home. A stage that reads no role is
inherited by the quests that name its section in a `[follows …]` tag, and a quest that writes a stage of the same
name keeps its own. A stage a quest inherits is told as the quest's: `! reached parcel(2).gone_home`.

## When the checker says no

cairn checks a story's quests inside `riverrun check`, and says what it finds in the same form as every other
diagnostic ([chapter 12](https://github.com/pedronaugusto/riverrun/blob/main/docs/manual/12-what-the-checker-proves.md)).
This copy, `mistakes/10/fair.river`, has no failure for the lost needles, misspells a stage in an `after`, and
names a key the game does not have:

```river refused
= paid         when { miller_paid }
  [objective] [after deliverd]
  Mrs Miller paid what she owed.
= done         when { delivered and paid and carrying hasnt money }
  [outcome] [after paid]
  [trust += 1]
  Otto has his money, and calls you a friend.

== cutpurse (quest)
```

```river refused
= robbed       when { purse_gone }
  [stage] [active watch]
  Somebody in the crowd has had your purse.
```

```console
$ riverrun check fair.river
fair.river:34:22-34:30: error: `deliverd` is not a stage of `errand`
fair.river:46:19-46:24: error: the game has no activation key `watch`
fair.river:25:4-25:10: error: `errand` can get stuck once `needles_lost` holds: no outcome or failure can be reached from there
```

The third is the stuck quest. The checker takes every effect the story writes as able to happen at any time, since
a player may come to it by many ways, and a fact the game writes as able to change any way; and it finds a state
from which no outcome and no failure can be reached: once `needles_lost` holds, `delivered` never can, so `done`
never can, and nothing else ends the errand. The message names what gets it there. Write the failure for it, as
`lost` is, or a way back.

This copy, `mistakes/10/ends/fair.river`, has the failure, but forgets that the needles may be lost after they were
delivered:

```river refused
= done         when { delivered and paid and carrying hasnt money }
  [outcome] [after paid]
  [trust += 1]
  Otto has his money, and calls you a friend.
= lost         when { needles_lost }
  [fails]
  Otto's needles went into the mud, and the pig after them.
```

```console
$ riverrun check fair.river
fair.river:40:3-40:7: error: `done` and `lost` can hold at once, and a quest ends once: make their conditions exclusive
```

For the checker, `needles_lost` can be set at any time, so after `done` too, and then both endings would hold: a
quest ends once. Say what keeps them apart: `lost` only while the needles are not delivered.

The checker holds the rest of a quest too: one kind to every stage, and a condition; `optional` only on an
objective; an ending never `live`; `after` going one way, never round; live stages that could keep changing each
other for ever; a quest's facts in the scope its stages are kept in; and a query a stage asks declaring what it
reads, `(reads …)`, so the quest wakes when its answer may change. A stage nothing the story does can reach is a
warning. What an int, a query or a builtin decides, the checker cannot follow, and says nothing of: `away` and
`late`, which wait on the clock, are the game's to bring about.

## For the programmer who wires the game

The game's vocabulary registers cairn, and lists the keys its world can show. This is the vocabulary these stories
are written for, [stories/vocabulary.zig](stories/vocabulary.zig), whole:

```zig
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
```

`packages` lists `cairn.package`, which brings the `quest` and `quest rules` kinds, their tags, `since` and `before`,
cairn's checks and the block it compiles into the story. The game's build hands cairn's compiler side to
riverrun's `addStory` as `cairn-compiler`, `cairn.compiler(b.dependency("cairn", riverrun.building(b)))`, as
[cairn's README](../../README.md) says and
[chapter 7](https://github.com/pedronaugusto/riverrun/blob/main/docs/manual/07-the-games-vocabulary.md#the-build)
shows for riverrun; the game runs the quests with `cairn.Quests` over the story's facts, as
[cairn's design](../design.md) says. In cairn's folder `bay manual` builds the `riverrun` program with this
vocabulary into `zig-out/bin`.

## Playing the fair

The game gives the player a parcel for Mrs Miller before the story starts, and two more as it goes. This is
`stories/10/fair.play`:

```console
$ riverrun play --set 'name(miller) = "Mrs Miller"' --call 'start parcel to=miller' --script fair.play fair.river
> :set name(miller) = "Mrs Miller"
> :start parcel to=miller
! roles cutpurse
  thief = thief, standing in for the game's
! started parcel(1)
! reached parcel(1).given
  A parcel from Otto's stall, for Mrs Miller.
  ? name(miller) = "Mrs Miller"
! active parcel_marked for parcel(1)
== fair
Lamps on poles, mud underfoot, and somebody's pig loose among the stalls.
== stall
OTTO: Needles, thread, buttons!
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> :start parcel to=pip
! started parcel(2)
! reached parcel(2).given
  A parcel from Otto's stall, for .
  ? name(pip) = "" (not set)
! active parcel_marked for parcel(2)
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> :set name(pip) = "Pip"
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> :start parcel to=ada
! started parcel(3)
! reached parcel(3).given
  A parcel from Otto's stall, for .
  ? name(ada) = "" (not set)
! active parcel_marked for parcel(3)
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> :set name(ada) = "Ada"
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> :set handed(miller) = true
! reached parcel(1).handed_over
  The parcel is with Mrs Miller.
  [trust += 1]
  ? name(miller) = "Mrs Miller"
! ended parcel(1).handed_over
! inactive parcel_marked for parcel(1)
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> 4
== mill
A door in the dark, and flour on the step.
MILLER: Who's that, at this hour?
MILLER: Oh, it's you. Thank you for the parcel.
* 1 (closed) Hand her the needles.
* 2 (closed) Ask for what she owes Otto.
* 3 Go back down to the fair.
> 3
== stall
OTTO: Needles, thread, buttons!
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> :set went_home(pip) = true
! reached parcel(2).gone_home
  Too late: Pip has gone home.
  ? name(pip) = "Pip"
! failed parcel(2).gone_home
! inactive parcel_marked for parcel(2)
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> :wait 3
! reached parcel(3).late
  Nobody came for the parcel. Otto has it back.
! failed parcel(3).late
! inactive parcel_marked for parcel(3)
* 1 Ask if he needs anything.
* 2 (closed) Give him Mrs Miller's money.
* 3 Go after the pig.
* 4 Walk up to the mill.
* 5 Go back to the ferry.
> 5
-> end
```

`--set` and `--call` are the first rows, as the game gave them; the first parcel's news is told before the fair's
heading, since the game started it before the story starts. `pip` and `ada` are the game's people, stood in for and named by `:set`. Mrs Miller's parcel is handed over
at the stall, and at the mill she thanks the player for it: `{ handed(miller) }` reads what the game set. Pip goes
home before the parcel reaches them, and the stage every quest with a `to` inherits fails that parcel; nobody comes
for Ada's, and three hours on it is late. Each instance keeps its own stages and its own mark on the map, and ends
on its own.
