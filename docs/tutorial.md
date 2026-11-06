# BeingDB Tutorial: Querying the REWIND Interviews

This tutorial teaches the BeingDB query language from first principles
using a real dataset: facts extracted from the
[REWIND](https://rewind.ac.uk/) archive of interviews with British and
international video artists, published at
[beingdb-rewind-interviews](https://github.com/jptmoore/beingdb-rewind-interviews).

You will clone the archive, compile it, and then work through
progressively richer questions:

| Part | You will learn |
|------|----------------|
| [1. Get the data](#part-1-get-the-data) | Clone, compile and open the REPL |
| [2. Explore](#part-2-explore-the-vocabulary) | Discover predicates and read results |
| [3. Basic queries](#part-3-basic-queries) | Variables, constants, wildcards, `distinct`, literal types |
| [4. Joins](#part-4-joins) | Combining facts, chains, self-joins, multi-hop paths |
| [5. Filters](#part-5-filtering) | Comparisons, ranges and text search |
| [6. Advanced](#part-6-optional-alternatives-and-absence) | `optional`, `either`/`or`, `not` |
| [7. Aggregation](#part-7-counting-ranking-and-paging) | `count`, `sum`, `avg`, `min`, `max`, ranking, `limit`/`offset` |
| [8. Debugging](#part-8-when-things-go-wrong) | Validation, diagnostics and query plans |
| [9. Beyond the REPL](#part-9-beyond-the-repl) | Query files, HTTP and updates |
| [10. Putting it together](#part-10-putting-it-together) | Capstone queries and exercises |

**Prerequisites:** BeingDB is installed and `beingdb` is on your `PATH`
(see [Installation](installation.md)). No knowledge of Prolog, SQL or
SPARQL is assumed.

> **About the data.** The facts were extracted from interview
> transcripts by a language model. They are a research artifact, not
> verified catalogue metadata. A result means "this relationship is
> recorded in the dataset", not "this is historically complete or
> correct". The examples in this tutorial were checked against archive
> commit `a561d79` (114 predicates, 1,778 facts); the archive may have
> grown since, so your counts can differ.

---

## Part 1: Get the data

### 1.1 Clone the archive

Create a working directory and clone the facts into a BeingDB Git store:

```bash
mkdir rewind-tutorial && cd rewind-tutorial

beingdb clone \
  https://github.com/jptmoore/beingdb-rewind-interviews.git \
  --git ./rewind_git
```

```
BeingDB Clone
Remote: https://github.com/jptmoore/beingdb-rewind-interviews.git
Local:  ./rewind_git

Initializing Git store...
Fetching from remote...
Successfully cloned repository
```

BeingDB only reads files under the repository's `predicates/` directory.
Each file holds the facts for one predicate, for example
`predicates/created_by.pl`:

```prolog
%! created_by(Work, Artist)
% Relates a work to the artist or artist group who made it.
created_by(absence_of_satan, george_barber).
created_by(all_the_pieces_i_never_did, david_critchley).
created_by(american_landscapes, judith_goddard).
```

The `%!` line is an optional *declaration*: it names each argument's
role and describes the predicate. You will see it again in the REPL.

`rewind_git/` is a store managed by BeingDB, not a normal working copy:
don't edit it or run `git pull` inside it. Section 9.3 shows how to
update it.

### 1.2 Compile

Queries run against a compiled, read-only *pack store*. Build it:

```bash
beingdb compile --git ./rewind_git --pack ./rewind_pack
```

```
BeingDB Compile
Source: Irmin Git (./rewind_git)
Target: Pack (./rewind_pack)

Found 114 predicates

✓ acquired_by (2 facts)
✓ affiliated_with (26 facts)
...
Compilation complete!
Predicates: 114
Total facts: 1778
```

Compilation parses every fact, checks that each predicate has a
consistent number of arguments, and builds indexes. Compiling again
replaces the pack store completely.

### 1.3 Open the REPL

```bash
beingdb repl --pack ./rewind_pack
```

```
BeingDB REPL. 114 predicates, fingerprint sha256:..., beingdb-dsl/1. Enter a find/where query (blank line to run), :help for commands, :quit to exit.
beingdb>
```

Two kinds of input are accepted at the prompt:

- **Commands** start with `:` and run immediately, e.g. `:help`.
- **Queries** span several lines. **Press Enter on an empty line to run
  the query.** This means a query must not contain blank lines.

Every query in this tutorial can be pasted directly at the prompt,
followed by an empty line.

---

## Part 2: Explore the vocabulary

You can't query a dataset without knowing its vocabulary, so start by
asking BeingDB what it contains.

### 2.1 List predicates

```text
:predicates
```

```
  created_by/2
  uses_medium/2
  interviewed_artist/1
  ...
```

`created_by/2` means the predicate `created_by` takes two arguments.
`interviewed_artist/1` takes one.

### 2.2 Describe a predicate

```text
:describe created_by
```

```
created_by/2  (133 facts)
  Relates a work to the artist or artist group who made it.
  arg 0 Work: atom
  arg 1 Artist: atom
  examples:
    created_by(static_acceleration, david_critchley)
    ...
```

This tells you the **argument order** (work first, artist second), the
**value type** of each argument (`atom`), how many facts exist, and some
examples. Always check argument order before writing a query; it is the
most common source of empty results.

Try a few more:

```text
:describe uses_medium
:describe year_created
:describe exhibited_at
:describe born_in
```

These predicates appear throughout the tutorial:

| Predicate | Meaning |
|-----------|---------|
| `interviewed_artist(Artist)` | An artist who is the subject of an interview |
| `person(Person)`, `work(Work)` | Entity-type markers |
| `created_by(Work, Artist)` | A work and who made it |
| `uses_medium(WorkOrArtist, Medium)` | A work or an artist's practice uses a medium |
| `year_created(Work, Year)` | A recorded year of creation |
| `exhibited_at(WorkOrArtist, VenueOrExhibition)` | Something shown somewhere |
| `collaborated_with(Person, Person)` | A recorded collaboration |
| `educated_at(Person, Institution)` | Where someone studied |
| `employed_by(Person, Organisation)` | Where someone worked or taught |
| `funded_by(WorkOrArtist, Funder)` | A funding relationship |
| `commissioned_by(Work, Commissioner)` | A commission |
| `interviewee(Interview, Artist)` | An interview and its subject |
| `source_url(Interview, Url)` | The interview transcript's URL |

Notice roles like `WorkOrArtist`: some predicates mix kinds of entity in
one position. Section 4.3 shows how to deal with that.

---

## Part 3: Basic queries

### 3.1 Your first query

Who was interviewed?

```text
find Artist
where
  interviewed_artist(Artist)
```

Every query has the same shape:

- **`find`** lists the columns you want back.
- **`where`** introduces the conditions, **one per line**.
- **`Artist`** starts with an uppercase letter, so it is a **variable**.
  BeingDB finds every fact matching `interviewed_artist(...)` and binds
  `Artist` to its value.

The REPL prints JSON:

```json
{
  "variables": [ "Artist" ],
  "results": [
    { "Artist": { "type": "atom", "value": "david_hall" } },
    { "Artist": { "type": "atom", "value": "rose_garrard" } },
    ...
  ],
  "count": 10,
  "total": 10,
  "hasMore": false,
  "truncated": false,
  "warnings": [],
  ...
}
```

Each value carries its **type** and **value**. The surrounding fields
describe the result set:

| Field | Meaning |
|-------|---------|
| `count` | Rows in this response |
| `total` | Rows the query matches in total |
| `hasMore` | More rows exist beyond this page |
| `truncated` | A server/REPL row cap (not your query) cut the results |
| `warnings` | Advisory messages worth reading |

There are 10 interviewed artists: `anna_ridley`, `david_critchley`,
`david_hall`, `george_barber`, `judith_goddard`, `kevin_atherton`,
`madelon_hooykaas`, `mike_stubbs`, `peter_donebauer` and `rose_garrard`.
They come back in no particular order; the next section shows how to
sort them.

For the rest of the tutorial, results are shown as compact tables
rather than raw JSON.

### 3.2 Sorting and limiting

Results have no guaranteed order unless you ask for one:

```text
find Work
where
  work(Work)
order by Work
limit 5
```

| Work |
|------|
| about_time |
| absence_of_satan |
| all_the_pieces_i_never_did |
| american_landscapes |
| an_audience_s_new_clothes |

`order by` sorts ascending by default; add `descending` (or `desc`) to
reverse. `limit` caps the number of rows returned. Here `total` is 175:
the query matched 175 works but returned 5.

### 3.3 Constants: fixing an argument

Write a lowercase value instead of a variable to fix that argument.
Which works did Kevin Atherton make?

```text
find Work
where
  created_by(Work, kevin_atherton)
order by Work
```

| Work |
|------|
| an_audience_s_new_clothes |
| another_sphere |
| any_questions |
| brixton_pieces |
| gallery_guide |
| in_two_minds |
| tape_tape |
| television_interview |
| the_eleventh_hour |
| the_tape |
| three_minute_16_millimetre_film_of_kevin_atherton_as_a_boxer |
| video_times |

The same predicate answers the reverse question. Who made `compass`?

```text
find Artist
where
  created_by(compass, Artist)
```

| Artist |
|--------|
| elsa_stansfield |
| madelon_hooykaas |

There is no "direction" in a query: any argument can be a variable or a
constant.

Values written in lowercase are **atoms**: identifiers like
`kevin_atherton`, not display names. Spelling must be exact.

### 3.4 Wildcards and `distinct`

Use `_` for an argument you don't care about. Who has made anything?

```text
find distinct Artist
where
  created_by(_, Artist)
order by Artist
```

Without `distinct`, an artist appears once per work. `distinct`
removes duplicate *rows from the output*: it keeps one row per distinct
combination of the `find` columns. This returns 19 creators.

Each `_` is independent and never appears in results.

### 3.5 Literal types matter

Every stored value has a type, determined by how it was written:

| Written as | Type | Example in this dataset |
|------------|------|-------------------------|
| `kevin_atherton` | atom | names, works, media |
| `"West Indies"` | string | `born_in(george_barber, "West Indies")` |
| `30` | integer | `duration_minutes(one_of_these_days, 30)` |
| `@1975` | year | `year_created(tape_tape, @1975)` |
| `"https://..."` | string | interview URLs |

Different types **never** match each other, so you must write constants
in the stored type:

```text
find Artist
where
  born_in(Artist, "West Indies")
```

| Artist |
|--------|
| george_barber |

```text
find Work
where
  year_created(Work, @1975)
order by Work
```

| Work |
|------|
| move_towards_the_verticality_of_the_horizon |
| tape_tape |
| videokalos |
| whats_it_to_you |
| zero_reaches_zeno |

`@1975` is a year. `1975` (integer), `"1975"` (string) and `@1975-01-01`
(a full date) are all different values. If you use the wrong type,
BeingDB tells you before running the query:

```text
find Work
where
  uses_medium(Work, "video")
```

```
literal_type_mismatch: Predicate 'uses_medium' argument 1 expects type in {atom}, got string
```

`:describe` shows the type of every argument, so check it whenever you
are unsure.

---

## Part 4: Joins

Real questions need more than one fact. In BeingDB, you combine facts
by **reusing a variable**.

### 4.1 Your first join

What media did Kevin Atherton's works use?

```text
find Work, Medium
where
  created_by(Work, kevin_atherton)
  uses_medium(Work, Medium)
order by Work, Medium
```

| Work | Medium |
|------|--------|
| gallery_guide | performance |
| gallery_guide | video |
| gallery_guide | video_projection |
| gallery_guide | virtual_reality |
| tape_tape | masking_tape |
| tape_tape | videotape |

Read the two lines as "**and**": find a `Work` created by Kevin Atherton
**and** that same `Work` uses some `Medium`. The shared variable `Work`
is the join.

Two things to notice:

1. A work with several media produces several rows.
2. Kevin made 12 works but only 2 appear: works with no recorded medium
   are excluded, because every line must match. Section 6.1 shows how
   to keep them.

### 4.2 Following a chain

Joins can chain through several relationships. Which interview
transcript should you read for each creator of a video work?

```text
find Artist, Work, Url
where
  uses_medium(Work, video)
  created_by(Work, Artist)
  interviewee(Interview, Artist)
  source_url(Interview, Url)
order by Artist, Work
```

| Artist | Work | Url |
|--------|------|-----|
| kevin_atherton | gallery_guide | https://rewind.ac.uk/.../KAT510.pdf |
| rose_garrard | incidents_in_a_garden | https://rewind.ac.uk/.../RG510.pdf |

This follows `Work → Artist → Interview → Url`. `Interview` is used only
to connect two lines, so it does not need to appear in `find`.

The order of lines in `where` does not matter: BeingDB's planner chooses
an efficient order itself.

### 4.3 Using joins to filter by kind

`exhibited_at` mixes works and artists in its first argument:

```text
find Thing
where
  exhibited_at(Thing, tate)
order by Thing
```

| Thing |
|-------|
| automotive_action_painting |
| david_critchley |
| flying_time |
| homing |
| rose_garrard |
| the_car_piece |

Add a join to keep only one kind. Works shown at the Tate, with their
creators:

```text
find Work, Artist
where
  exhibited_at(Work, tate)
  created_by(Work, Artist)
order by Work, Artist
```

| Work | Artist |
|------|--------|
| automotive_action_painting | george_barber |
| flying_time | elsa_stansfield |
| flying_time | madelon_hooykaas |
| homing | mike_stubbs |

Interviewed artists recorded as exhibited at the Tate:

```text
find Artist
where
  exhibited_at(Artist, tate)
  interviewed_artist(Artist)
order by Artist
```

| Artist |
|--------|
| david_critchley |
| rose_garrard |

A join with a "type" predicate like `interviewed_artist`, `person` or
`work` is the standard way to narrow a mixed position.

### 4.4 Self-joins: the same predicate twice

Using a predicate twice with different variables lets you compare facts
with each other. Which works have more than one recorded creator?

```text
find Work, Artist, OtherArtist
where
  created_by(Work, Artist)
  created_by(Work, OtherArtist)
  Artist != OtherArtist
order by Work, Artist
limit 6
```

| Work | Artist | OtherArtist |
|------|--------|-------------|
| compass | elsa_stansfield | madelon_hooykaas |
| compass | madelon_hooykaas | elsa_stansfield |
| day_for_night | elsa_stansfield | madelon_hooykaas |
| day_for_night | madelon_hooykaas | elsa_stansfield |
| deep_looking | elsa_stansfield | madelon_hooykaas |
| deep_looking | madelon_hooykaas | elsa_stansfield |

`Artist != OtherArtist` removes rows where both variables matched the
same fact. Each pair appears twice, once in each order. You cannot
remove the mirror rows with `Artist < OtherArtist`, because atoms are
not ordered (BeingDB rejects it with `comparison_type_mismatch`).

Who studied at the same institution?

```text
find Place, Artist, Classmate
where
  educated_at(Artist, Place)
  educated_at(Classmate, Place)
  Artist != Classmate
order by Place, Artist, Classmate
```

| Place | Artist | Classmate |
|-------|--------|-----------|
| ealing_school_of_art | elsa_stansfield | madelon_hooykaas |
| ealing_school_of_art | madelon_hooykaas | elsa_stansfield |
| royal_college_of_art | david_critchley | david_hall |
| ... | ... | ... |
| slade_school_of_fine_art | elsa_stansfield | george_barber |
| slade_school_of_fine_art | george_barber | elsa_stansfield |

The 26 rows pair up five people at the Royal College of Art, and
connect Elsa Stansfield and George Barber through the Slade. This works
because the archive uses one atom per institution: BeingDB matches
values exactly and does not reconcile names, so `royal_college` and
`royal_college_of_art` would be two different places. Section 5.3 shows
how to match name variants in data that has them.

### 4.5 Reciprocal relationships

`collaborated_with` is recorded from the point of view of whichever
interview mentioned it, so it is not automatically symmetric. Which
collaborations are recorded in **both** directions?

```text
find A, B
where
  collaborated_with(A, B)
  collaborated_with(B, A)
order by A, B
```

| A | B |
|---|---|
| anna_ridley | david_hall |
| david_hall | anna_ridley |
| elsa_stansfield | madelon_hooykaas |
| judith_goddard | kev_fraser |
| kev_fraser | judith_goddard |
| madelon_hooykaas | elsa_stansfield |

And which interviewed artists are recorded as collaborating with another
interviewed artist?

```text
find A, B
where
  interviewed_artist(A)
  interviewed_artist(B)
  collaborated_with(A, B)
order by A, B
```

| A | B |
|---|---|
| anna_ridley | david_hall |
| david_critchley | david_hall |
| david_critchley | kevin_atherton |
| david_hall | anna_ridley |
| kevin_atherton | david_hall |
| madelon_hooykaas | david_hall |
| rose_garrard | anna_ridley |

`david_hall` is a hub in this network.

### 4.6 Multi-hop paths

Chain the same relationship to walk further. Who are the collaborators
of Kevin Atherton's collaborators?

```text
find distinct Other
where
  collaborated_with(kevin_atherton, Middle)
  collaborated_with(Middle, Other)
  Other != kevin_atherton
order by Other
```

| Other |
|-------|
| anna_ridley |
| barry_flanagan |
| channel_4 |
| david_cunningham |
| jeffrey_shaw |
| john_latham |
| mark_kidel |
| stuart_brisley |
| tony_sinden |

Each extra hop is another line with a new variable. BeingDB has no
recursive "any number of hops" operator; you write out the hops you
want.

(`channel_4` is an organisation: extracted data is not always tidy. A
join with `person(Other)` would remove it.)

### 4.7 Every pattern must be connected

Each line must share a variable (or constant) with the rest of the
query. This is rejected:

```text
find Artist, Work
where
  interviewed_artist(Artist)
  work(Work)
```

```
disconnected_query: ...
```

Unconnected patterns would pair every artist with every work, which is
almost never what you want. If you get this error, check for a typo in a
variable name.

---

## Part 5: Filtering

### 5.1 Comparisons

A `where` line can also be a comparison. Supported operators are `=`,
`!=`, `<`, `<=`, `>`, `>=`, `between ... and ...` and `contains`.

Works created in the 1970s, with their creators:

```text
find Year, Work, Artist
where
  created_by(Work, Artist)
  year_created(Work, Year)
  Year >= @1970
  Year < @1980
order by Year, Work
```

`between` is inclusive at both ends and is often clearer:

```text
find Year, Work, Artist
where
  created_by(Work, Artist)
  year_created(Work, Year)
  Year between @1970 and @1979
order by Year, Work
```

Both return the same 17 rows, starting:

| Year | Work | Artist |
|------|------|--------|
| 1971 | time_check | david_hall |
| 1973 | changing | david_critchley |
| 1973 | vertical_roll | joan_jonas |
| 1975 | move_towards_the_verticality_of_the_horizon | david_critchley |
| ... | ... | ... |

Comparisons work on integers too:

```text
find Work, Minutes
where
  duration_minutes(Work, Minutes)
  Minutes > 10
```

| Work | Minutes |
|------|---------|
| one_of_these_days | 30 |

### 5.2 Type rules for comparisons

Comparisons respect types:

- Numbers compare with numbers, years with years, dates with dates.
- An integer may be compared with a year as a convenience, so
  `Year >= 1970` also works. Writing `@1970` makes the intent clearer.
- A year is never compared with a full date. This is rejected:

  ```text
  find Work
  where
    year_created(Work, Y)
    Y > @1975-01-01
  ```

  ```
  comparison_type_mismatch: Cannot compare a year with a date.
  ```

- Atoms and strings support `=`, `!=` and `contains`, but not `<` or
  `>`.
- `=` and `!=` **filter** rows; they never bind a variable. Every
  variable in a comparison must also appear in a pattern.

### 5.3 Text search with `contains`

An exact constant only matches one value. `uses_medium(Work, video)`
misses `colour_video`, `videotape` and `video_projection`. Use
`contains` to match part of a value:

```text
find distinct Medium
where
  uses_medium(_, Medium)
  Medium contains "video"
order by Medium
```

| Medium |
|--------|
| black_and_white_video |
| colour_video |
| live_video |
| single_tape_video |
| video |
| video_camera |
| video_projection |
| videotape |

`contains` ignores case and treats `_` and spaces as the same, so
`"royal college"` matches the atom `royal_college_of_art`. That helps
with naming variants:

```text
find Artist, Place
where
  educated_at(Artist, Place)
  Place contains "royal college"
order by Artist
```

| Artist | Place |
|--------|-------|
| david_critchley | royal_college_of_art |
| david_hall | royal_college_of_art |
| judith_goddard | royal_college_of_art |
| mike_stubbs | royal_college_of_art |
| peter_donebauer | royal_college_of_art |

It also helps you find duplicate entities before relying on a name:

```text
find Name
where
  person(Name)
  Name contains "critchley"
```

| Name |
|------|
| dave_critchley |
| david_critchley |

`contains` is a plain substring test: no wildcards or regular
expressions. The left side must be a variable and the search text must
be in double quotes.

Strings work the same way. Find the transcript URL for a document code:

```text
find Artist, Url
where
  interviewee(Interview, Artist)
  source_url(Interview, Url)
  Url contains "KAT510"
```

| Artist | Url |
|--------|-----|
| kevin_atherton | https://rewind.ac.uk/rewind/wp-content/uploads/sites/146/2021/03/KAT510.pdf |

---

## Part 6: Optional, alternatives and absence

Plain `where` lines all have to match. Three block keywords relax that:
`optional`, `either`/`or` and `not`.

**Layout rule for all blocks:** a block runs until the next block
keyword (`optional`, `either`, `or`, `not`) or the end of the clauses
(`order by`, `limit`, `offset`). Indentation is only for readability.
Put the required lines first, then the blocks. Blocks cannot be nested.

### 6.1 `optional`: keep rows with missing information

In section 4.1, Kevin's works without a recorded medium disappeared.
`optional` keeps them:

```text
find Work, Medium
where
  created_by(Work, kevin_atherton)
  optional
    uses_medium(Work, Medium)
order by Work, Medium
```

| Work | Medium |
|------|--------|
| an_audience_s_new_clothes | *null* |
| another_sphere | *null* |
| any_questions | *null* |
| brixton_pieces | *null* |
| gallery_guide | performance |
| gallery_guide | video |
| ... | ... |

When the optional block does not match, its variables come back as JSON
`null`. All 12 works now appear.

You can use several `optional` blocks. Each is matched independently:

```text
find Year, Work, Medium, Venue
where
  created_by(Work, Artist)
  interviewed_artist(Artist)
  year_created(Work, Year)
  Year between @1975 and @1976
  optional
    uses_medium(Work, Medium)
  optional
    exhibited_at(Work, Venue)
order by Year, Work, Medium, Venue
```

A comparison placed inside an `optional` block only affects that block.
For example, putting `Year > @1980` inside an optional `year_created`
block keeps every work but only shows years after 1980.

### 6.2 `either` / `or`: alternatives

Rows are kept if **any** branch matches. Works recorded with either of
two exact media, and their creators:

```text
find distinct Artist, Work
where
  created_by(Work, Artist)
  either
    uses_medium(Work, video)
  or
    uses_medium(Work, videotape)
order by Artist, Work
```

| Artist | Work |
|--------|------|
| elsa_stansfield | sea_of_light |
| kevin_atherton | gallery_guide |
| kevin_atherton | tape_tape |
| madelon_hooykaas | sea_of_light |
| rose_garrard | incidents_in_a_garden |

`tape_tape` is recorded with `videotape` rather than `video`, so the
second branch is what finds it.

Branches can contain several lines, including comparisons. Who was
commissioned by the BBC, or funded by Channel 4?

```text
find distinct Thing, Organisation
where
  either
    commissioned_by(Thing, Organisation)
    Organisation contains "bbc"
  or
    funded_by(Thing, Organisation)
    Organisation contains "channel"
order by Thing
```

| Thing | Organisation |
|-------|--------------|
| homing | bbc |
| london_video_arts | channel_4 |
| luminous_portrait | bbc |
| mike_stubbs | channel_4 |
| taxi_driver_ii | channel_4 |
| this_is_a_television_receiver | bbc_2 |
| venetian_ghost | channel_4 |

A variable that only one branch binds is `null` in rows from the other
branch. Section 10.1 uses this to tell apart two kinds of answer.

### 6.3 `not`: absence

`not` keeps a row only when the block has **no** match. Which
interviewed artists have no recorded education?

```text
find Artist
where
  interviewed_artist(Artist)
  not
    educated_at(Artist, _)
order by Artist
```

| Artist |
|--------|
| anna_ridley |

Which of Kevin Atherton's works have no recorded year?

```text
find Work
where
  created_by(Work, kevin_atherton)
  not
    year_created(Work, _)
order by Work
```

This returns 11 of his 12 works; only `tape_tape` has a year.

Two rules:

- Every **named** variable inside `not` must also be bound outside it.
  Use `_` for anything else. A variable that only appears inside `not`
  is rejected as `unsafe_negation`.
- **Absence in the data is not absence in the world.** "No recorded
  education" means the interviews did not mention it, not that the
  artist never studied.

---

## Part 7: Counting, ranking and paging

### 7.1 Counting

`count(Var)` counts **distinct** values of `Var`:

```text
find count(Work)
where
  created_by(Work, kevin_atherton)
```

| count(Work) |
|-------------|
| 12 |

### 7.2 Grouping

Other variables in `find` act as groups. Number of works per creator,
largest first:

```text
find Artist, count(Work)
where
  created_by(Work, Artist)
order by count(Work) descending, Artist
limit 5
```

| Artist | count(Work) |
|--------|-------------|
| elsa_stansfield | 24 |
| madelon_hooykaas | 23 |
| george_barber | 18 |
| kevin_atherton | 12 |
| david_critchley | 10 |

The second sort key, `Artist`, makes ties appear in a stable order.

Counts are only as clean as the data: if one artist were recorded under
two identifiers, their works would be split across two rows. Use
`contains` (section 5.3) to look for variants before trusting a
ranking.

The most frequent funders:

```text
find Funder, count(Thing)
where
  funded_by(Thing, Funder)
order by count(Thing) descending, Funder
limit 5
```

| Funder | count(Thing) |
|--------|--------------|
| arts_council_of_great_britain | 11 |
| channel_4 | 4 |
| bbc | 2 |
| buddhist_broadcasting_foundation | 2 |
| gulbenkian_foundation | 2 |

Works per year, as a timeline:

```text
find Year, count(Work)
where
  created_by(Work, _)
  year_created(Work, Year)
order by Year
```

| Year | count(Work) |
|------|-------------|
| 1968 | 1 |
| 1971 | 1 |
| 1973 | 2 |
| 1975 | 5 |
| 1976 | 2 |
| ... | ... |

### 7.3 Counting zero

A plain join drops groups with nothing to count. Combine `count` with
`optional` to include them as `0`:

```text
find Artist, count(Org)
where
  interviewed_artist(Artist)
  optional
    employed_by(Artist, Org)
order by count(Org) descending, Artist
```

| Artist | count(Org) |
|--------|------------|
| kevin_atherton | 9 |
| rose_garrard | 5 |
| madelon_hooykaas | 4 |
| david_hall | 3 |
| ... | ... |
| judith_goddard | 0 |

Rules for `count`:

- It counts distinct values, so a join that repeats a value does not
  inflate the count.
- Don't also put the counted variable in `find` as a plain column.
- In a counting query, `order by` can only use `find` columns, including
  `count(...)`.

### 7.4 Earliest, latest and totals

`min`, `max`, `sum` and `avg` work like `count`, with the same grouping.
Each artist's first and last dated work:

```text
find Artist, count(Work), min(Year), max(Year)
where
  created_by(Work, Artist)
  year_created(Work, Year)
order by count(Work) descending, Artist
limit 5
```

| Artist | count(Work) | min(Year) | max(Year) |
|--------|-------------|-----------|-----------|
| elsa_stansfield | 9 | 1975 | 1990 |
| madelon_hooykaas | 9 | 1975 | 1990 |
| david_critchley | 4 | 1973 | 1977 |
| david_hall | 2 | 1968 | 1971 |
| mike_stubbs | 2 | 1983 | 2003 |

`count(Work)` here counts only works with a recorded year, because the
join with `year_created` drops the others.

Totals and averages need numbers. The recorded running times:

```text
find count(Work), sum(Minutes), avg(Minutes), min(Minutes), max(Minutes)
where
  duration_minutes(Work, Minutes)
```

| count(Work) | sum(Minutes) | avg(Minutes) | min(Minutes) | max(Minutes) |
|-------------|--------------|--------------|--------------|--------------|
| 2 | 36 | 18 | 6 | 30 |

Rules for `sum`, `avg`, `min` and `max`:

- `sum` and `avg` need integers or decimals; `min` and `max` also take
  years and dates. `find sum(Artist) ...` is rejected with
  `invalid_aggregate`.
- They read each distinct combination of the query's named variables
  once, so name the thing you are adding up: `duration_minutes(Work,
  Minutes)`, not `duration_minutes(_, Minutes)`, which would add two
  18-minute works once (BeingDB warns with `aggregate_wildcard`).
  Conversely, an extra named variable in another join can add the same
  work twice.
- `avg` is a decimal; `min` and `max` keep the value's type.

### 7.5 Paging

`limit` sets the page size and `offset` skips rows. The second page of
five:

```text
find Artist, count(Work)
where
  created_by(Work, Artist)
order by count(Work) descending, Artist
limit 5
offset 5
```

Always use `order by` when paging so pages are stable. Use `total` and
`hasMore` in the response to tell whether more pages exist.

---

## Part 8: When things go wrong

### 8.1 Errors are caught before running

BeingDB validates every query against the compiled data. A misspelled
predicate:

```text
find Work
where
  creatd_by(Work, kevin_atherton)
```

```
unknown_predicate: Unknown predicate 'creatd_by'; did you mean: created_by, curated_by, edited_by, funded_by, co_edited_by?
```

### 8.2 Empty results are explained

A misspelled *constant* is valid syntax, so the query runs and returns
nothing, but the response explains why:

```text
find Work
where
  created_by(Work, kevin_athertn)
```

```json
"diagnostics": [
  {
    "code": "unknown_constant",
    "message": "'kevin_athertn' does not occur in any fact, so created_by(...) cannot match it. Did you mean kevin_atherton?",
    ...
  }
],
"provablyEmpty": true
```

`provablyEmpty: true` means BeingDB has proved that the query can never
match the current data. Read the diagnostics before concluding that "the
answer is none".

### 8.3 Validate, diagnose and explain without running

Three REPL commands take a query (enter the command, then the query,
then an empty line):

| Command | What it does |
|---------|--------------|
| `:validate` | Checks syntax, predicates, arities and types |
| `:diagnose` | Validation plus data-aware checks and suggested repairs |
| `:explain` | Shows the execution plan |

```text
:explain
find Work, Year
where
  created_by(Work, kevin_atherton)
  year_created(Work, Year)
  Year >= @1975
```

```
created_by: equality_index(position=1, value=kevin_atherton)
year_created: range_index(position=1, lower=1975, upper=unbounded)
```

The planner looks up Kevin's works through an index, then checks the
year through a range index, rather than scanning every fact.

### 8.4 Troubleshooting checklist

| Symptom | Likely cause |
|---------|--------------|
| `syntax_error` | Missing `where`, two clauses on one line, a trailing `.`, or a blank line inside the query |
| `unknown_predicate` / arity error | Check `:predicates` and `:describe` |
| `literal_type_mismatch` | `"video"` vs `video`, `1975` vs `@1975`; check `:describe` |
| `comparison_type_mismatch` | Comparing year with date, or ordering atoms |
| `disconnected_query` | A line shares no variable with the rest; often a typo |
| `unsafe_negation` | A named variable appears only inside `not` |
| Unbound variable in comparison | A comparison uses a variable no pattern binds |
| Empty result | Wrong argument order, wrong spelling or type; read `diagnostics` |
| Too many repeated rows | Several matches per join; use `distinct` or fewer columns |
| `result_too_large`, `scan_limit_exceeded`, timeout | Add constants or filters; `limit` does not reduce work |

---

## Part 9: Beyond the REPL

### 9.1 Query files

Save queries to a file, separated by blank lines:

```bash
cat > rewind.query <<'EOF'
find Artist
where
  interviewed_artist(Artist)
order by Artist

find Funder, count(Thing)
where
  funded_by(Thing, Funder)
order by count(Thing) descending, Funder
limit 5
EOF
```

Run them all from the REPL:

```text
:loadqueries rewind.query
```

### 9.2 HTTP API

Serve the same pack store over HTTP (quit the REPL first):

```bash
beingdb serve --pack ./rewind_pack --port 8080
```

In another terminal, list predicates with their declarations:

```bash
curl 'http://localhost:8080/predicates?detailed=true&names=created_by,collaborated_with'
```

Send a query. JSON strings need `\n` for line breaks:

```bash
curl -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Work\nwhere\n  created_by(Work, kevin_atherton)\norder by Work"}'
```

To send a query file without hand-escaping, let `jq` build the JSON:

```bash
cat > tate.query <<'EOF'
find Work, Artist
where
  exhibited_at(Work, tate)
  created_by(Work, Artist)
order by Work, Artist
EOF

jq -Rs '{query: .}' tate.query \
  | curl -s -X POST http://localhost:8080/query \
      -H 'Content-Type: application/json' --data-binary @-
```

Add `"action": "validate"`, `"diagnose"` or `"explain"` to the JSON body
to get the same results as the REPL commands. Paging belongs in the
query text (`limit`, `offset`), not in the JSON body. See the
[API reference](api.md) for all endpoints and limits.

### 9.3 Updating the archive

When the archive gains new interviews, pull and recompile (stop the
server and REPL first):

```bash
beingdb pull \
  https://github.com/jptmoore/beingdb-rewind-interviews.git \
  --git ./rewind_git

beingdb compile --git ./rewind_git --pack ./rewind_pack
```

Pulling alone does not change query results; compiling does.

---

## Part 10: Putting it together

### 10.1 Capstone: who funded each interviewed artist?

Funding is sometimes recorded against the artist and sometimes against
a specific work. `either`/`or` collects both, and `Work` stays `null`
for artist-level funding:

```text
find distinct Artist, Funder, Work
where
  interviewed_artist(Artist)
  either
    funded_by(Artist, Funder)
  or
    created_by(Work, Artist)
    funded_by(Work, Funder)
order by Artist, Funder, Work
```

| Artist | Funder | Work |
|--------|--------|------|
| david_critchley | arts_council_of_great_britain | *null* |
| david_critchley | northern_arts | *null* |
| david_hall | arts_council_of_great_britain | vertical |
| david_hall | arts_council_of_great_britain | *null* |
| david_hall | british_council | *null* |
| george_barber | arts_council_of_great_britain | *null* |
| george_barber | channel_4 | taxi_driver_ii |
| ... | ... | ... |

### 10.2 Capstone: a research worksheet

For every work by an interviewed artist dated 1970–1989, list its
media and exhibition venues where recorded, plus the transcript to check
them against:

```text
find Year, Artist, Work, Medium, Venue, Url
where
  interviewed_artist(Artist)
  created_by(Work, Artist)
  year_created(Work, Year)
  Year between @1970 and @1989
  interviewee(Interview, Artist)
  source_url(Interview, Url)
  optional
    uses_medium(Work, Medium)
  optional
    exhibited_at(Work, Venue)
order by Year, Artist, Work, Medium, Venue
```

This one query uses most of the language: an entity-type filter, a
four-step chain, a range comparison, two independent optional blocks
and ordering. It returns 34 rows; a work appears once per combination
of medium and venue.

Remember what the result is: a list of claims extracted from
interviews, with the transcript that each artist's claims came from.
Each fact's supporting quote is recorded in the archive's
`metadata/evidence/` directory, which you can read in an ordinary
`git clone` of the archive.

### 10.3 Exercises

Try each one before opening the solution.

1. Which institutions did George Barber study at?
2. Which interviewed artists are recorded as collaborating with
   `david_hall`?
3. List every work from 1975, with its creator and any recorded media.
4. Which three interviewed artists have the most recorded
   collaborators?
5. Which interviewed artists were employed by an organisation whose
   name contains "college" or "school"?
6. Which works were commissioned, by whom, and who made them?

<details>
<summary>Solution 1</summary>

```text
find Place
where
  educated_at(george_barber, Place)
order by Place
```

`slade_school_of_fine_art`, `st_martins`.

</details>

<details>
<summary>Solution 2</summary>

```text
find Artist
where
  interviewed_artist(Artist)
  collaborated_with(Artist, david_hall)
order by Artist
```

`anna_ridley`, `david_critchley`, `kevin_atherton`, `madelon_hooykaas`.

</details>

<details>
<summary>Solution 3</summary>

```text
find Work, Artist, Medium
where
  year_created(Work, @1975)
  created_by(Work, Artist)
  optional
    uses_medium(Work, Medium)
order by Work, Artist, Medium
```

Eight rows; works such as `zero_reaches_zeno` have no recorded medium,
so `Medium` is `null`.

</details>

<details>
<summary>Solution 4</summary>

```text
find Artist, count(Person)
where
  interviewed_artist(Artist)
  collaborated_with(Artist, Person)
order by count(Person) descending, Artist
limit 3
```

`david_critchley` (23), `mike_stubbs` (22), `kevin_atherton` (13).

</details>

<details>
<summary>Solution 5</summary>

```text
find distinct Artist, Org
where
  interviewed_artist(Artist)
  employed_by(Artist, Org)
  either
    Org contains "college"
  or
    Org contains "school"
order by Artist, Org
```

Eight rows, including `david_hall` at `kingston_college` and
`maidstone_college_of_art`.

</details>

<details>
<summary>Solution 6</summary>

```text
find Artist, Work, Commissioner
where
  created_by(Work, Artist)
  commissioned_by(Work, Commissioner)
order by Artist, Work, Commissioner
```

Six rows, for example `judith_goddard`'s `luminous_portrait`,
commissioned by both `bbc` and `late_show`.

</details>

---

## Where next

- [Query Language](query-language.md): the complete reference for the
  DSL, every literal type, and query limits.
- [API Reference](api.md): HTTP endpoints, request options and server
  configuration.
- [Getting Started](getting-started.md): building your own facts
  repository.
- [beingdb-rewind-interviews](https://github.com/jptmoore/beingdb-rewind-interviews):
  how the dataset was extracted, and its evidence files.
