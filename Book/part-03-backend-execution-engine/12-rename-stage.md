# Chapter 12. Rename Stage

Decode ended the previous chapter with a much better internal description of each instruction: XiangShan now knows the
logical source and destination registers, the functional-unit class, the split/uop boundaries, and a large amount of
exception and vector-control metadata. That is necessary for an out-of-order backend. It is still not sufficient.

Issue queues, wakeup networks, and physical register files do not operate on logical names such as `x7`, `f3`, or
`v12`. They operate on **physical tags** — unique identifiers drawn from a pool that is typically much larger than the
architectural register space. They also need those tags to remain precise across speculation, commit, and recovery.
The rename stage is the boundary where XiangShan turns decoded instructions into speculative backend work items with
explicit physical dependencies.

In Kunminghu, rename is broader than the textbook phrase "map architectural registers to physical registers." The
current RTL also assigns `robIdx`, supports integer move elimination, renames five separate namespaces
(`int`, `fp`, `vec`, `v0`, and `vl`), cooperates with the memory-dependence predictor, decides when rename snapshots
are created, and rebuilds speculative state after redirects. The stage is instantiated in `CtrlBlock` at
[CtrlBlock.scala:101](src/main/scala/xiangshan/backend/CtrlBlock.scala#L101).

This chapter follows the same zoom-in method as Chapter 11. We begin with the problem rename solves, place the stage
in backend context, describe its interfaces, then walk through the real data path and recovery behavior in the RTL.

## 12.1 Motivation and Design Challenge

If you keep one question in mind, the rest of the chapter becomes much easier to read:

> **How does XiangShan turn decoded instructions that still speak in logical register names into speculative backend
> uops that can execute out of order and still recover precisely?**

### 12.1.1 Why logical names are no longer enough

Architecturally, the instruction `add x8, x1, x2` is simple: read two registers and write one result.
Microarchitecturally, that description hides two problems that prevent a naive out-of-order machine from working
correctly.

**The first problem is name conflicts.** Consider two instructions that both write `x8`:

```
add  x8, x1, x2    # Instruction A: writes x8
sub  x8, x3, x4    # Instruction B: also writes x8
```

If the machine has only one physical storage location named `x8`, then B's write can destroy A's result before a still
older consumer reads it, or A's late write can overwrite B's correct value if A executes after B. These are the classic
**write-after-write (WAW)** and **write-after-read (WAR)** hazards. In an in-order pipeline, the hazards are handled by
stalling. In an out-of-order machine, instructions may execute and complete in any order, so stalling is too
restrictive. The solution is to give each write a *different* physical storage location, so that the two "x8"s do not
interfere with each other. That is the fundamental idea behind register renaming.

**The second problem is recovery.** An out-of-order machine speculates past branches. If the branch turns out to be
mispredicted, the machine must undo any register-name mappings that were created along the wrong path, without
corrupting the committed architectural view. That requires the rename state to be both speculative and recoverable.

Rename therefore answers several concrete questions for every decoded uop window.

| Rename question | Example answer | Why it matters |
| --------------- | -------------- | -------------- |
| Which physical tag supplies each source? | `x1 -> p14`, `x2 -> p37` | Issue queues and register files consume physical tags, not logical names. |
| Does the destination need a fresh tag? | `x8` gets a new integer physical register; `mv x6, x5` may reuse `p5` | New tags eliminate WAW/WAR hazards, but move elimination can avoid unnecessary allocation. |
| Which ROB entry owns the instruction? | One `robIdx` for this instruction, or a shared ROB entry if compression applies | Rename is where XiangShan makes ROB-allocation decisions. |
| When can the old destination tag be returned? | Only after commit proves the old tag is no longer architecturally live | Premature freeing would let a younger instruction overwrite a still-visible value. |
| How is wrong-path rename state repaired? | Restore RAT/free-list state from snapshot or committed state, then walk | Precise recovery requires the speculative and committed views to stay synchronized. |

In XiangShan, those answers come from the coordinated behavior of `Rename.scala`,
[RenameTable.scala](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L48),
[StdFreeList.scala](src/main/scala/xiangshan/backend/rename/freelist/StdFreeList.scala#L28),
[MEFreeList.scala](src/main/scala/xiangshan/backend/rename/freelist/MEFreeList.scala#L27), and the snapshot control in
[CtrlBlock.scala:535](src/main/scala/xiangshan/backend/CtrlBlock.scala#L535).

### 12.1.2 Rename is speculative namespace management

One useful mental model is that rename manages two parallel naming systems at once, much like how a version-control
system maintains both a working copy and a committed revision.

- The **architectural view** says each logical register name has one committed meaning. This is the "last known good"
  state — the view that would be visible if the machine stopped speculating right now. It corresponds to the committed
  head of a version-control repository.
- The **speculative view** says each in-flight write may temporarily redefine that meaning for younger instructions.
  This is the working copy — it reflects all the in-flight changes that have not yet been proven correct.

The rename tables therefore maintain both a speculative mapping (`spec_table`) and a committed mapping (`arch_table`)
inside each register namespace
([RenameTable.scala:113](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L113) to
[RenameTable.scala:117](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L117)).
The free lists maintain an analogous split between a speculative allocation head (`headPtr`) and an architectural head
(`archHeadPtr`)
([BaseFreeList.scala:67](src/main/scala/xiangshan/backend/rename/freelist/BaseFreeList.scala#L67) to
[BaseFreeList.scala:69](src/main/scala/xiangshan/backend/rename/freelist/BaseFreeList.scala#L69)).

That parallel structure is what makes precise recovery possible. When a mispredicted path is detected, the machine
discards the speculative working copy and restores either from a snapshot (a lightweight checkpoint, like a saved
bookmark) or from the committed architectural state (the equivalent of reverting to the last clean commit). The
committed mappings remain intact throughout.

### 12.1.3 XiangShan-specific requirements

Rename in Kunminghu is harder than the one-table examples found in introductory microarchitecture texts. Five
properties of the real design push complexity well beyond a simple "one integer RAT" toy model.

1. **The stage is wide.** `DecodeWidth`, `RenameWidth`, and `RabCommitWidth` are `8` by default
   ([Parameters.scala:80](src/main/scala/xiangshan/Parameters.scala#L80) to
   [Parameters.scala:84](src/main/scala/xiangshan/Parameters.scala#L84)), but a backend-V2 configuration reduces them
   to `6`
   ([Configs.scala:510](src/main/scala/top/Configs.scala#L510) to
   [Configs.scala:512](src/main/scala/top/Configs.scala#L512)).
   A width of 8 means the stage must handle up to 8 instructions simultaneously, and any instruction in the window may
   depend on any older instruction in the same window. The intra-window dependency check is therefore an O(n^2)
   combinational structure, not a simple per-lane pipeline.

2. **The current RTL renames five namespaces**, not just integer and floating-point. `Rename.scala` instantiates
   separate free lists for `int`, `fp`, `vec`, `v0`, and `vl`
   ([Rename.scala:111](src/main/scala/xiangshan/backend/rename/Rename.scala#L111) to
   [Rename.scala:115](src/main/scala/xiangshan/backend/rename/Rename.scala#L115)),
   and `RenameTableWrapper` instantiates matching rename tables
   ([RenameTable.scala:254](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L254) to
   [RenameTable.scala:258](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L258)).
   Each namespace has independent physical pool sizes, allocation logic, and recovery state. The `v0` and `vl`
   namespaces exist because the RISC-V vector extension treats the mask register `v0` and the vector-length register
   `vl` as distinct from the general vector register file, and XiangShan wants to rename them independently so that
   mask and vector-length producers do not contend with general vector operands.

3. **Rename also owns compression-aware `robIdx` assignment.** It runs `CompressUnit`, tracks `robIdxHead`, and counts
   only those uops that actually need a new ROB entry
   ([CompressUnit.scala:40](src/main/scala/xiangshan/backend/rename/CompressUnit.scala#L40) to
   [CompressUnit.scala:114](src/main/scala/xiangshan/backend/rename/CompressUnit.scala#L114),
   [Rename.scala:324](src/main/scala/xiangshan/backend/rename/Rename.scala#L324) to
   [Rename.scala:336](src/main/scala/xiangshan/backend/rename/Rename.scala#L336)).

4. **Integer rename supports move elimination.** When `isMove` is true, rename suppresses integer physical-register
   allocation and reuses the physical tag of the source operand
   ([Rename.scala:399](src/main/scala/xiangshan/backend/rename/Rename.scala#L399) to
   [Rename.scala:402](src/main/scala/xiangshan/backend/rename/Rename.scala#L402),
   [Rename.scala:676](src/main/scala/xiangshan/backend/rename/Rename.scala#L676),
   [Rename.scala:727](src/main/scala/xiangshan/backend/rename/Rename.scala#L727)).
   This is a common high-performance optimization: if `mv x6, x5` simply means "x6 should read the same physical
   register as x5," there is no need to allocate a new physical register, copy the data, and then free the old tag.
   Instead, the rename table can just point x6 at x5's existing physical tag.

5. **Recovery is distributed.** Snapshot state lives in the RATs, the free lists, the ROB-side snapshot queue in
   `CtrlBlock`, and other backend structures. Rename decides when a snapshot is worth creating, but `CtrlBlock`
   decides which snapshot to restore on redirect
   ([Rename.scala:745](src/main/scala/xiangshan/backend/rename/Rename.scala#L745) to
   [Rename.scala:773](src/main/scala/xiangshan/backend/rename/Rename.scala#L773),
   [CtrlBlock.scala:540](src/main/scala/xiangshan/backend/CtrlBlock.scala#L540) to
   [CtrlBlock.scala:582](src/main/scala/xiangshan/backend/CtrlBlock.scala#L582)).

The rename stage is therefore where XiangShan's dependency naming, ROB naming, and recovery naming all meet.

## 12.2 Subsystem Context in Full-Chip View

At full-chip level, rename is the last control-oriented stage before dispatch turns renamed uops into scheduler inputs.
Decode still describes work in logical register names. Dispatch already assumes physical tags exist and uses busy tables
to classify sources as ready or not ready
([NewDispatch.scala:246](src/main/scala/xiangshan/backend/dispatch/NewDispatch.scala#L246) to
[NewDispatch.scala:275](src/main/scala/xiangshan/backend/dispatch/NewDispatch.scala#L275),
[NewDispatch.scala:304](src/main/scala/xiangshan/backend/dispatch/NewDispatch.scala#L304) to
[NewDispatch.scala:358](src/main/scala/xiangshan/backend/dispatch/NewDispatch.scala#L358)).
Rename is the seam between those two worlds.

```mermaid
flowchart LR
  DEC["DecodeStage output<br/>Vec[DecodeOutUop] x RenameWidth"]
  RATADDR["Decode-driven RAT read addresses"]
  FUS["Fusion sideband<br/>validVec / isFusionVec / fusionInfo"]
  MDP["SSIT + waittable"]
  ROB["ROB commit/walk + redirect"]

  subgraph REN["Rename Subsystem"]
    CU["CompressUnit<br/>ROB grouping"]
    RAT["RenameTableWrapper<br/>int / fp / vec / v0 / vl"]
    FL["Free lists<br/>ME int + Std fp / vec / v0 / vl"]
    BY["Bypass + move elimination<br/>psrc / pdest repair"]
    SN["Snapshot generation"]
  end

  DISP["Dispatch"]

  DEC --> CU
  DEC --> BY
  FUS --> CU
  RATADDR --> RAT
  RAT --> BY
  FL --> BY
  MDP --> BY
  ROB --> RAT
  ROB --> FL
  ROB --> SN
  CU --> BY
  BY --> DISP
  SN --> RAT
  SN --> FL
  BY --> SN
  DISP -->|ready/backpressure| BY
```

**Figure 12.1: Rename subsystem in backend context.** The stage is not only a RAT lookup. It combines ROB grouping,
multi-namespace register allocation, same-window bypass, and distributed recovery control.

The main left-to-right path is:

1. `DecodeStage` emits `DecodeOutUop` records and, through `CtrlBlock`, drives the RAT read ports directly
   ([CtrlBlock.scala:527](src/main/scala/xiangshan/backend/CtrlBlock.scala#L527) to
   [CtrlBlock.scala:531](src/main/scala/xiangshan/backend/CtrlBlock.scala#L531)).
2. `RenameTableWrapper` returns the speculative physical mappings for the requested logical source names.
3. The free lists provide candidate new physical destinations, one namespace at a time.
4. Rename repairs same-window dependencies, applies move elimination, assigns `robIdx`, and emits `RenameOutUop`.
5. Dispatch then interprets those tags with busy tables and reg-cache state, but it no longer needs logical register
   names to determine dependencies.

Two feedback structures matter just as much as the forward path.

- `ROB -> Rename` carries commit, walk, and redirect information, so rename can both free old tags and rebuild
  speculative state.
- `MDP -> Rename` carries `SSIT` and waittable results, allowing rename to attach dependency-prediction hints before
  dispatch
  ([CtrlBlock.scala:657](src/main/scala/xiangshan/backend/CtrlBlock.scala#L657) to
  [CtrlBlock.scala:660](src/main/scala/xiangshan/backend/CtrlBlock.scala#L660),
  [Rename.scala:427](src/main/scala/xiangshan/backend/rename/Rename.scala#L427) to
  [Rename.scala:433](src/main/scala/xiangshan/backend/rename/Rename.scala#L433)).

One timing detail is easy to miss in a block diagram: decode and rename are slightly overlapped. The RAT reads are
launched in decode, while the returned physical tags are consumed in rename. XiangShan does this because the RAT read
path is pipelined rather than fully combinational
([RenameTable.scala:122](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L122) to
[RenameTable.scala:156](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L156)).
This is an important timing optimization that we will examine closely in Section 12.4.4.

## 12.3 Module Boundary and External Interfaces

At the stage boundary, the most important transformation is from `DecodeOutUop` to `RenameOutUop`. Understanding the
difference between these two bundles is the key to understanding what rename adds.

| Bundle | Defined in | Role at the rename boundary |
| ------ | ---------- | --------------------------- |
| [`DecodeOutUop`](src/main/scala/xiangshan/backend/Bundles.scala#L136) | [Bundles.scala:136](src/main/scala/xiangshan/backend/Bundles.scala#L136) | Decode's logical description: logical sources/destination, FU classification, split metadata, immediates, and exception-side information. |
| [`RenameOutUop`](src/main/scala/xiangshan/backend/Bundles.scala#L230) | [Bundles.scala:230](src/main/scala/xiangshan/backend/Bundles.scala#L230) | Rename's backend contract: physical source tags, physical destination tags, `robIdx`, snapshot marker, dependency-predictor sideband, and extra bookkeeping such as `numLsElem` and `hasException`. |
| [`SnapshotPort`](src/main/scala/xiangshan/Bundle.scala#L411) | [Bundle.scala:411](src/main/scala/xiangshan/Bundle.scala#L411) | Common distributed-control bundle used to enqueue, dequeue, flush, and select rename snapshots across RATs and free lists. |

`RenameOutUop` makes the backend-visible changes explicit. Relative to `DecodeOutUop`, it adds `psrc`, `psrcVl`,
`pdest`, `pdestVl`, `robIdx`, `snapshot`, `storeSetHit`, `loadWaitBit`, `loadWaitStrict`, `ssid`, `numLsElem`, and
`hasException`
([Bundles.scala:269](src/main/scala/xiangshan/backend/Bundles.scala#L269) to
[Bundles.scala:296](src/main/scala/xiangshan/backend/Bundles.scala#L296)).
This is the exact point where "logical dependency information" becomes "scheduler-ready dependency information." Before
rename, the backend knows that an instruction reads `x1`. After rename, the backend knows that the instruction reads
physical register `p14`, which may or may not be ready yet. That distinction is what allows the out-of-order scheduler
to operate purely on physical tag matching, without ever consulting logical register names again.

The `Rename` module interface reflects that broader job description.

| Interface group | RTL hook | Purpose |
| --------------- | -------- | ------- |
| Decode inputs | [Rename.scala:65](src/main/scala/xiangshan/backend/rename/Rename.scala#L65) to [Rename.scala:70](src/main/scala/xiangshan/backend/rename/Rename.scala#L70) | The decoded uop window plus fusion sideband that survived the decode-to-rename pipeline. |
| RAT ports | [Rename.scala:75](src/main/scala/xiangshan/backend/rename/Rename.scala#L75) to [Rename.scala:79](src/main/scala/xiangshan/backend/rename/Rename.scala#L79) | Read ports for integer, FP, vector, `v0`, and `vl` logical namespaces. Decode drives the addresses; rename consumes the returned data. |
| Predictor sideband | [Rename.scala:71](src/main/scala/xiangshan/backend/rename/Rename.scala#L71) to [Rename.scala:74](src/main/scala/xiangshan/backend/rename/Rename.scala#L74) | Memory-dependence predictor hints from `SSIT` and waittable. |
| Recovery and commit | [Rename.scala:59](src/main/scala/xiangshan/backend/rename/Rename.scala#L59) to [Rename.scala:63](src/main/scala/xiangshan/backend/rename/Rename.scala#L63), [Rename.scala:83](src/main/scala/xiangshan/backend/rename/Rename.scala#L83) to [Rename.scala:92](src/main/scala/xiangshan/backend/rename/Rename.scala#L92) | Redirect, commit, walk, and snapshot control. |
| Dispatch output | [Rename.scala:81](src/main/scala/xiangshan/backend/rename/Rename.scala#L81) | The renamed uop window sent toward dispatch. |

Three terms will recur throughout the chapter.

- **Speculative RAT (Register Alias Table).** The map used by younger in-flight instructions. When a new instruction
  writes to logical register `x8`, the speculative RAT immediately records the new physical tag so that even younger
  instructions in the pipeline can find the correct producer. This is `spec_table` inside each `RenameTable`
  ([RenameTable.scala:113](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L113)).
- **Architectural RAT.** The committed map. This reflects only instructions that have been confirmed correct by the ROB.
  It is the "ground truth" that the machine can always fall back to during recovery. This is `arch_table`
  ([RenameTable.scala:116](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L116)).
- **Walk.** ROB-driven re-rename after a redirect. During walk, rename stops sending new work to dispatch and instead
  rebuilds speculative mappings from ROB-supplied state
  ([Rename.scala:289](src/main/scala/xiangshan/backend/rename/Rename.scala#L289) to
  [Rename.scala:296](src/main/scala/xiangshan/backend/rename/Rename.scala#L296),
  [Rename.scala:552](src/main/scala/xiangshan/backend/rename/Rename.scala#L552)).
  Think of walk as the machine saying: "I jumped back to a snapshot, but the snapshot was taken too early; now I need
  to replay the rename decisions from the snapshot point up to the redirect point, to get the speculative RAT into the
  exact state it should have been in."

## 12.4 Internal Pipeline and Data-Path Walkthrough

The rename data path is easiest to understand if we separate its long-lived state from its per-window combinational
work. The long-lived state consists of the rename tables (RATs) and the free lists. The per-window work is everything
that happens combinationally within a single rename cycle: reading source tags, allocating destination tags, repairing
intra-window dependencies, and assigning ROB indices.

### 12.4.1 One stage, five rename namespaces

Before diving into the namespace table, it helps to understand what a **free list** is and why each namespace needs one.

A free list is a data structure that tracks which physical registers are currently not in use and can be handed out to
new instructions. When a new instruction needs to write to a logical register, the free list provides a fresh physical
register number. When an old instruction commits and its previous physical mapping becomes dead (no longer needed by any
in-flight or committed instruction), that physical register is returned to the free list.

The free list is conceptually a circular buffer of physical register identifiers. Allocation advances a "head" pointer
forward; freeing pushes identifiers back onto the "tail." The distance between head and tail tells the machine how many
physical registers are still available. If the free list is empty, rename must stall — there is no room to create new
speculative state.

Current Kunminghu rename is explicitly multi-namespace. Each namespace gets its own RAT and its own free list, because
the physical register files for integer, floating-point, vector, mask, and vector-length values are all separate
hardware structures.

| Namespace | Logical space | Physical pool | Concrete state in rename | Special behavior |
| --------- | ------------- | ------------- | ------------------------ | ---------------- |
| Integer | [`IntLogicRegs`](src/main/scala/xiangshan/Parameters.scala#L91) = 32 | [`intPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L116) = 224 | `intRat` + `MEFreeList` | Supports move elimination and duplicate-aware freeing. |
| Floating-point | [`FpLogicRegs`](src/main/scala/xiangshan/Parameters.scala#L92) = 34 | [`fpPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L122) = 256 | `fpRat` + `StdFreeList` | Includes internal logical names beyond the ISA's 32 FP registers. |
| Vector | [`VecLogicRegs`](src/main/scala/xiangshan/Parameters.scala#L93) = 47 | [`vfPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L128) = 128 | `vecRat` + `StdFreeList` | Includes temporary vector logical names. |
| `v0` | [`V0LogicRegs`](src/main/scala/xiangshan/Parameters.scala#L94) = 1 | [`v0Preg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L134) = 22 | `v0Rat` + `StdFreeList` | Dedicated mask-register namespace. |
| `vl` | [`VlLogicRegs`](src/main/scala/xiangshan/Parameters.scala#L95) = 1 | [`vlPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L140) = 32 | `vlRat` + `StdFreeList` | Dedicated vector-length namespace with separate `pdestVl` / `psrcVl`. |

This table is worth emphasizing because it corrects an easy oversimplification. Some older summaries speak mainly in
terms of integer, floating-point, and vector rename tables. The current RTL is more explicit: `RenameTableWrapper`
instantiates five tables
([RenameTable.scala:254](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L254) to
[RenameTable.scala:258](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L258)),
and `Rename.scala` instantiates five matching allocation structures
([Rename.scala:111](src/main/scala/xiangshan/backend/rename/Rename.scala#L111) to
[Rename.scala:115](src/main/scala/xiangshan/backend/rename/Rename.scala#L115)).

Notice the two different free-list types. The integer namespace uses `MEFreeList` (Move Elimination Free List), which
has extra bookkeeping to handle the fact that multiple logical registers can share one physical register after a move.
The other four namespaces use `StdFreeList` (Standard Free List), which is simpler because they do not support move
elimination.

The free-list base class already shows the recovery-oriented state each namespace maintains: speculative head,
architectural head, and snapshot copies of the head pointer
([BaseFreeList.scala:64](src/main/scala/xiangshan/backend/rename/freelist/BaseFreeList.scala#L64) to
[BaseFreeList.scala:85](src/main/scala/xiangshan/backend/rename/freelist/BaseFreeList.scala#L85)).
The RAT side mirrors this with `spec_table`, `arch_table`, and snapshot copies of the speculative map
([RenameTable.scala:113](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L113) to
[RenameTable.scala:146](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L146)).

### 12.4.2 Admission is conservative and bundle-wide

Rename does not partially accept an arbitrary suffix of the window once the head instruction is present. Instead, it
uses a stage-wide admission rule. The idea is simple: either the entire window advances, or nothing advances.

This is a deliberate design choice. Consider the alternative: if rename accepted only the first 3 of 8 instructions
because the integer free list was running low, the RAT and free-list state would advance by 3, but the remaining 5
would stay behind. On the next cycle, those 5 would arrive with stale RAT read results (because the RAT has already
been updated by the first 3). Handling partial advancement correctly would require extra buffering and re-reading
logic. XiangShan avoids that complexity by using an all-or-nothing policy.

- Each free list computes `canAllocate` from an available-count check against the full `RenameWidth`
  ([StdFreeList.scala:64](src/main/scala/xiangshan/backend/rename/freelist/StdFreeList.scala#L64) to
  [StdFreeList.scala:66](src/main/scala/xiangshan/backend/rename/freelist/StdFreeList.scala#L66),
  [MEFreeList.scala:78](src/main/scala/xiangshan/backend/rename/freelist/MEFreeList.scala#L78) to
  [MEFreeList.scala:82](src/main/scala/xiangshan/backend/rename/freelist/MEFreeList.scala#L82)).
  In other words, each free list checks whether it has at least `RenameWidth` (8 by default) registers available. This
  is conservative — not all 8 lanes may actually need a destination in that namespace — but it guarantees that no lane
  will be denied a register mid-window.
- `Rename.scala` then defines `canOut` as the conjunction of dispatch readiness, all five `canAllocate` signals, and
  `!io.rabCommits.isWalk`
  ([Rename.scala:289](src/main/scala/xiangshan/backend/rename/Rename.scala#L289) to
  [Rename.scala:296](src/main/scala/xiangshan/backend/rename/Rename.scala#L296)).
- Every input lane shares the same readiness condition once lane 0 is valid
  ([Rename.scala:464](src/main/scala/xiangshan/backend/rename/Rename.scala#L464) to
  [Rename.scala:465](src/main/scala/xiangshan/backend/rename/Rename.scala#L465)).

The result is a deliberately conservative policy: rename only advances when it can sustain a full-width, internally
consistent handoff to dispatch. This simplifies RAT/free-list synchronization and recovery logic at the cost of
occasionally stalling the whole window because one namespace is close to empty.

The `doAllocate` signal for each free list illustrates a subtle coordination mechanism: each free list's `doAllocate`
depends on the `canAllocate` of all the *other* free lists plus dispatch readiness
([Rename.scala:289](src/main/scala/xiangshan/backend/rename/Rename.scala#L289) to
[Rename.scala:293](src/main/scala/xiangshan/backend/rename/Rename.scala#L293)).
This cross-check ensures that no single namespace commits to advancing its head pointer unless every other namespace
is also ready. It prevents a situation where, say, the integer free list allocates 8 registers but the vector free list
cannot, leading to inconsistent state.

### 12.4.3 Compression-aware `robIdx` assignment

Rename in XiangShan owns `robIdxHead`, so it also owns the decision about how many ROB entries the current rename
window consumes. This may seem surprising — one might expect the ROB itself to manage its own indexing — but it makes
sense when you consider that rename already has the decode-side information needed to decide which instructions can
share a ROB entry.

`CompressUnit` takes the decoded window, filters for instructions that are valid, exception-free, at a `lastUop`
boundary, and marked `canRobCompress`, then generates three outputs:

- `needRobFlags`: which lanes actually consume a new ROB entry.
- `instrSizes`: how many architectural instructions belong to the compressed group containing that lane.
- `masks`: which lanes belong to the same ROB-compressed group.

That logic is implemented entirely inside
[CompressUnit.scala:52](src/main/scala/xiangshan/backend/rename/CompressUnit.scala#L52) to
[CompressUnit.scala:114](src/main/scala/xiangshan/backend/rename/CompressUnit.scala#L114).

Rename then uses those results to advance `robIdxHead` by only the count of valid `lastUop` lanes whose
`needRobFlag` is true
([Rename.scala:324](src/main/scala/xiangshan/backend/rename/Rename.scala#L324) to
[Rename.scala:336](src/main/scala/xiangshan/backend/rename/Rename.scala#L336)).
On redirect, `robIdxHead` resets to the redirect target ROB index; on a misprediction that does not flush the
redirecting instruction itself, the next cycle adds one more entry
([Rename.scala:331](src/main/scala/xiangshan/backend/rename/Rename.scala#L331) to
[Rename.scala:335](src/main/scala/xiangshan/backend/rename/Rename.scala#L335)).

The `robIdxHead` update logic at
[Rename.scala:332](src/main/scala/xiangshan/backend/rename/Rename.scala#L332) to
[Rename.scala:335](src/main/scala/xiangshan/backend/rename/Rename.scala#L335)
is a priority `Mux` chain that handles three cases in order of priority: redirect (jump to target index), misprediction
recovery (increment by one from the redirected position), and normal advance (increment by the number of valid new ROB
entries). If none of these conditions is met, the head pointer holds its current value.

This is why rename, not ROB or dispatch, is the right place to understand XiangShan's ROB naming policy. The stage
already has the decode-side compression and fusion information that determines how many ROB entries the window should
consume.

### 12.4.4 Source tags come from pipelined RAT reads plus local repair

The physical source-tag path has two layers. Understanding both is essential, because the first layer alone would
produce incorrect results for instructions that depend on other instructions in the same rename window.

**Layer 1: Pipelined RAT lookup.** `RenameTable` makes the main array read synchronous, pipelines the addresses, and
explicitly bypasses T0 writes into T1 read results
([RenameTable.scala:122](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L122) to
[RenameTable.scala:156](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L156)).

To understand why this is pipelined, consider what a "synchronous read" means. In a purely combinational RAT, you
present an address and immediately get back the data in the same cycle. That is fast for narrow designs but creates
long combinational paths when the RAT is wide (8 lanes of reads and writes per cycle). XiangShan instead registers the
read addresses: decode presents the logical register addresses in cycle T, the RAT array is read in cycle T+1, and the
physical tags emerge for rename to consume in T+1. This is why decode launches RAT read addresses one stage earlier
([CtrlBlock.scala:527](src/main/scala/xiangshan/backend/CtrlBlock.scala#L527) to
[CtrlBlock.scala:531](src/main/scala/xiangshan/backend/CtrlBlock.scala#L531)).

But pipelining introduces a hazard: what if the RAT was written in T0 (by the previous rename window), and a T0+1
read needs that just-written value? The RAT handles this with explicit write bypass: if a T0 write targets the same
logical address that a T0 read requested, the bypass path forwards the T0 write data into the T1 result
([RenameTable.scala:152](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L152) to
[RenameTable.scala:156](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L156)).

**Layer 2: Local repair inside rename (same-window bypass).** The pipelined RAT lookup handles dependencies between
consecutive rename windows. But what about dependencies *within* the same window?

Consider a window of two instructions:

```
Lane 0: add x8, x1, x2    (writes x8)
Lane 1: sub x9, x8, x3    (reads x8)
```

When lane 1's RAT read for `x8` was launched (in the previous cycle, during decode), lane 0's write to `x8` had not
yet happened — it happens in the current rename cycle. So the RAT returns the *old* physical tag for `x8`, which is
wrong for lane 1.

Rename fixes this with a same-window bypass network. For every lane `i > 0`, rename checks whether any older lane
`j < i` in the same window writes to the same logical register that lane `i` reads. If so, lane `i`'s `psrc` is
replaced with lane `j`'s newly allocated `pdest`
([Rename.scala:680](src/main/scala/xiangshan/backend/rename/Rename.scala#L680) to
[Rename.scala:727](src/main/scala/xiangshan/backend/rename/Rename.scala#L727)).

The bypass condition check at
[Rename.scala:697](src/main/scala/xiangshan/backend/rename/Rename.scala#L697) to
[Rename.scala:708](src/main/scala/xiangshan/backend/rename/Rename.scala#L708)
compares each source of lane `i` against each destination of lanes `0..i-1`. The comparison checks both the logical
register index (`ldest === lsrc`) and the namespace match (the source type must match the destination's register
class). The result is stored in `bypassCond(j)(i-1)`, a bit vector indicating which older lanes should override lane
`i`'s source `j`.

The actual bypass application uses a fold-left pattern. Starting from the RAT-provided `psrc`, it iterates over all
older lanes from 0 to `i-1`. If the bypass condition is true for an older lane, that lane's `pdest` replaces the
current value. Because the fold processes lanes in order, a later (younger) matching lane naturally takes priority over
an earlier one — which is exactly the correct behavior when multiple older lanes write to the same logical register.

The initial `srcType`-based selection logic picks the correct namespace's RAT output for each source operand:

- `srcType` selects whether `psrc(0..2)` should come from integer, FP, or vector RAT data.
- `psrc(3)` always comes from the dedicated `v0` RAT.
- `psrcVl` comes from the dedicated `vl` RAT.

That selection is coded in
[Rename.scala:523](src/main/scala/xiangshan/backend/rename/Rename.scala#L523) to
[Rename.scala:527](src/main/scala/xiangshan/backend/rename/Rename.scala#L527).
Fusion sideband can further override integer `rs2` handling for fused pairs
([Rename.scala:529](src/main/scala/xiangshan/backend/rename/Rename.scala#L529) to
[Rename.scala:535](src/main/scala/xiangshan/backend/rename/Rename.scala#L535)).

### 12.4.5 Destination allocation, move elimination, and namespace-specific writes

Once source tags are resolved, rename must decide which instructions need fresh physical destination registers and
allocate them from the appropriate free lists.

**Destination need computation.** Rename computes one `need*Dest` bit per namespace and per lane from the decode-side
write-enable information
([Rename.scala:438](src/main/scala/xiangshan/backend/rename/Rename.scala#L438) to
[Rename.scala:443](src/main/scala/xiangshan/backend/rename/Rename.scala#L443)).
For example, `needIntDest(i)` is true when lane `i` is valid and the instruction writes an integer register (as
indicated by `rfWen` in the decoded uop). Similarly, `needFpDest(i)` checks for FP writes, `needVecDest(i)` for
vector writes, and so on.

**Free-list allocation.** Those bits feed the free lists:

- `fp`, `vec`, `v0`, and `vl` simply allocate when their corresponding write-enable is set
  ([Rename.scala:453](src/main/scala/xiangshan/backend/rename/Rename.scala#L453) to
  [Rename.scala:460](src/main/scala/xiangshan/backend/rename/Rename.scala#L460)).
- Integer rename suppresses allocation for move-eliminated instructions
  ([Rename.scala:461](src/main/scala/xiangshan/backend/rename/Rename.scala#L461)).
  This is the line `intFreeList.io.allocateReq(i) := needIntDest(i) && !isMove(i)`: even though a move instruction
  writes to an integer destination, the free list is told not to allocate a new physical register.

**Provisional destination tag.** The provisional destination tag comes straight from the relevant free list
([Rename.scala:539](src/main/scala/xiangshan/backend/rename/Rename.scala#L539) to
[Rename.scala:547](src/main/scala/xiangshan/backend/rename/Rename.scala#L547)).
A `MuxCase` selects among the five free lists based on which `needDest` bit is set. For most instructions, this is the
final destination tag.

**Move elimination.** Integer moves then overwrite that provisional choice with `psrc(0)`, so `pdest` becomes "the
same physical value, now under a second logical name"
([Rename.scala:676](src/main/scala/xiangshan/backend/rename/Rename.scala#L676),
[Rename.scala:727](src/main/scala/xiangshan/backend/rename/Rename.scala#L727)).

To understand why this works, consider `mv x6, x5`. Normally, this would mean: allocate a new physical register `pN`,
copy the value of `x5`'s current physical register into `pN`, and update the RAT to map `x6 -> pN`. With move
elimination, rename skips all of that. Instead, it looks up `x5`'s current physical tag (say `p14`), and simply updates
the RAT to map `x6 -> p14`. Now both `x5` and `x6` point to the same physical register. No data copy is needed, no
execution unit is consumed, and no new physical register is allocated.

Such instructions also set `numWB := 0`, because the move was eliminated instead of creating new execution work.
The same `numWB := 0` treatment also applies to instructions with certain exceptions, since those instructions will
never produce a writeback result either
([Rename.scala:470](src/main/scala/xiangshan/backend/rename/Rename.scala#L470) to
[Rename.scala:472](src/main/scala/xiangshan/backend/rename/Rename.scala#L472)).

This detail propagates into the next stage. Dispatch marks newly allocated integer destinations busy only when
`!isMove`
([NewDispatch.scala:255](src/main/scala/xiangshan/backend/dispatch/NewDispatch.scala#L255) to
[NewDispatch.scala:265](src/main/scala/xiangshan/backend/dispatch/NewDispatch.scala#L265)).
That is exactly what we want: a move-eliminated instruction renames a logical destination, but it does not create a
new not-ready physical register. From the scheduler's perspective, the destination tag is already "ready" because it
is the same physical register that already holds the source value.

### 12.4.6 Rename adds more than tags

Although register renaming is the stage's name, the output work record is richer than just `psrc` and `pdest`.
Rename is the last stage that sees the full decoded instruction context before dispatch breaks it into
scheduler-specific paths, so it is a natural place to attach metadata that dispatch and later stages will need.

First, rename attaches memory-dependence predictor sideband.

- `storeSetHit`, `loadWaitStrict`, and `ssid` come from `SSIT`.
- `loadWaitBit` comes from the waittable.

Those assignments are made in
[Rename.scala:427](src/main/scala/xiangshan/backend/rename/Rename.scala#L427) to
[Rename.scala:433](src/main/scala/xiangshan/backend/rename/Rename.scala#L433).
These fields allow the load-store unit to enforce predicted ordering constraints between loads and stores, reducing
the number of costly memory-ordering violations that would otherwise require pipeline flushes.

Second, vector memory uops receive a derived `numLsElem` value based on vector type, EEW, SEW, LMUL, and segment/unit
stride information
([Rename.scala:350](src/main/scala/xiangshan/backend/rename/Rename.scala#L350) to
[Rename.scala:389](src/main/scala/xiangshan/backend/rename/Rename.scala#L389)).

Third, rename carries forward compression-aware bookkeeping such as `numWB`, `crossFtq`, `dirtyFs`, and `dirtyVs`
([Rename.scala:489](src/main/scala/xiangshan/backend/rename/Rename.scala#L489) to
[Rename.scala:520](src/main/scala/xiangshan/backend/rename/Rename.scala#L520)).

The important lesson is that XiangShan rename is already shaping backend execution semantics, not merely translating
register names.

```mermaid
flowchart TB
  A["1. Decode lane provides lsrc / ldest,<br/>srcType, fuType, split metadata"] --> B["2. Decode-launched RAT read returns<br/>candidate physical source tags"]
  B --> C["3. Rename decides which namespaces<br/>need a destination allocation"]
  C --> D["4. Free lists return candidate<br/>pdest / pdestVl"]
  D --> E["5. Intra-window bypass repairs RAW chains;<br/>integer move may set pdest := psrc0"]
  E --> F["6. CompressUnit + robIdxHead decide<br/>which uops consume ROB entries"]
  F --> G["7. RenameOutUop leaves the stage with<br/>psrc, pdest, robIdx, snapshot, predictor sideband"]
  G --> H["8. Speculative RAT records new mapping<br/>unless redirect or walk blocks the write"]
```

**Figure 12.2: Step-by-step rename data flow.** The figure compresses the stage into one narrative: read speculative
source mappings, allocate or reuse destination tags, repair same-window dependencies, assign ROB ownership, then publish
the updated speculative mapping.

## 12.5 Control, Recovery, and Snapshot Behavior

Rename's correctness depends on three histories staying aligned:

- the speculative RAT mappings,
- the free-list allocation heads,
- and the ROB position of the in-flight work.

If any one of these drifts out of sync with the others — for example, if the RAT says `x8 -> p50` but `p50` has already
been returned to the free list — the machine will silently produce wrong results. The control behavior looks complicated
at first, but most of it reduces to three modes: normal rename, redirect response, and walk-based rebuild. Each mode has
one overriding goal: keep those three histories consistent.

### 12.5.1 Commit-time reclamation of old mappings

When an instruction commits, the machine is certain that its rename decision was correct. At that point, the physical
register that *used to* be mapped to the same logical destination is no longer needed by any future instruction — all
future instructions will use the new mapping. The old physical register can therefore be returned to the free list for
reuse.

However, "can be returned" is more nuanced than it sounds. The old tag must not be freed if it is still alive under
a different logical name (which can happen with move elimination), and if multiple instructions commit in the same
cycle and write the same logical destination, the intermediate old tags must be handled correctly.

Inside `RenameTable`, `archWritePorts` update `arch_table`, while `old_pdest` captures the physical tag that used to be
architecturally mapped at that logical destination
([RenameTable.scala:159](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L159) to
[RenameTable.scala:168](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L168)).
This capture includes same-cycle bypass among multiple commit ports, so if two commit lanes write the same logical
destination, the younger port sees the older port's just-written value as its `old_pdest`
([RenameTable.scala:163](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L163) to
[RenameTable.scala:166](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L166)).

Integer rename then adds one more protection: `need_free` is asserted only if the old tag no longer appears anywhere in
the architectural integer RAT and is not duplicated by an earlier commit lane in the same batch
([RenameTable.scala:170](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L170) to
[RenameTable.scala:174](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L174)).
That duplicate check is exactly what move elimination needs. After `mv x6, x5`, both `x5` and `x6` may point to the
same physical register `p14`. If a later instruction writes a new value to `x6` and then that instruction commits,
the old `pdest` of `x6` is `p14`. But `p14` must *not* be freed, because `x5` still points to it in the architectural
RAT. The `need_free` check catches this: it scans the entire architectural RAT and suppresses freeing if any other
entry still references `p14`.

`Rename.scala` consumes those signals and turns them into actual free-list returns
([Rename.scala:778](src/main/scala/xiangshan/backend/rename/Rename.scala#L778) to
[Rename.scala:814](src/main/scala/xiangshan/backend/rename/Rename.scala#L814)).
FP, vector, `v0`, and `vl` freeing are simpler: commit plus the corresponding write-enable is enough to return the old
tag. Integer freeing must additionally respect `int_need_free`.

```mermaid
sequenceDiagram
  participant D as Decode
  participant R as RAT Wrapper
  participant N as Rename
  participant P as Dispatch
  participant C as ROB Commit/Walk

  Note over D,R: Cycle T
  D->>R: logical source addresses
  D->>N: DecodeOutUop enters decode→rename pipe

  Note over R,N: Cycle T+1
  R-->>N: physical source tags
  N->>N: allocate/reuse pdest, bypass same-window deps, assign robIdx
  N->>R: speculative RAT write
  N-->>P: RenameOutUop

  Note over C,R: Later commit cycle
  C->>R: arch RAT write or walk write
  R-->>N: old_pdest (+ need_free for int)
  N->>N: return reclaimable tags to free lists
```

**Figure 12.3: Cycle-level timing view of normal rename and later commit.** The diagram highlights the two-stage source
lookup (`Decode -> RAT -> Rename`) and the later commit-time reclamation path (`ROB -> RAT -> free list`).

### 12.5.2 Snapshot generation

Rename snapshots exist to shorten recovery. Without snapshots, every misprediction would require the machine to restore
the architectural RAT (which may be very far behind the speculative state) and then "walk" through every correctly
speculated instruction between the architectural head and the misprediction point, replaying their rename decisions one
by one. For a deep pipeline with hundreds of in-flight instructions, that walk could take many cycles.

A snapshot captures the speculative RAT state and the free-list head pointer at a particular point in program order. If
a misprediction occurs *after* that snapshot point, the machine can restore from the snapshot instead of from the much
older architectural state, dramatically reducing the number of instructions that need to be walked.

The policy for creating snapshots is intentionally selective. Not every instruction gets a snapshot — the storage cost
would be too high. Instead, snapshots are created at control-flow instructions (branches and jumps), because those are
the points where mispredictions can occur.

`Rename.scala` generates a snapshot candidate only when:

- rename snapshots are enabled,
- the new snapshot is sufficiently far from the most recent one,
- the previous cycle did not already create another snapshot,
- the head input is a `firstUop`,
- and the firing instruction is a jump/control-flow instruction.

That logic is in
[Rename.scala:745](src/main/scala/xiangshan/backend/rename/Rename.scala#L745) to
[Rename.scala:752](src/main/scala/xiangshan/backend/rename/Rename.scala#L752).
The minimum spacing is `4 * RobCommitWidth`
([Rename.scala:748](src/main/scala/xiangshan/backend/rename/Rename.scala#L748)),
which is `32` ROB positions under the default `RobCommitWidth = 8`
([Parameters.scala:83](src/main/scala/xiangshan/Parameters.scala#L83)).
This spacing prevents the snapshot buffer from being filled by a burst of closely spaced branches, which would waste
storage on snapshots that cover very little speculative state.

Once `genSnapshot` is asserted, rename fans that enqueue event to all five free lists
([Rename.scala:764](src/main/scala/xiangshan/backend/rename/Rename.scala#L764) to
[Rename.scala:773](src/main/scala/xiangshan/backend/rename/Rename.scala#L773)),
while `CtrlBlock` mirrors the same event onto the RAT-side snapshot port
([CtrlBlock.scala:578](src/main/scala/xiangshan/backend/CtrlBlock.scala#L578) to
[CtrlBlock.scala:582](src/main/scala/xiangshan/backend/CtrlBlock.scala#L582)).
`CtrlBlock` also stores central metadata about the snapshot: the `robIdx` vector of the renamed bundle and which lane
held the control-flow instruction
([CtrlBlock.scala:540](src/main/scala/xiangshan/backend/CtrlBlock.scala#L540) to
[CtrlBlock.scala:544](src/main/scala/xiangshan/backend/CtrlBlock.scala#L544)).

One subtle but important integration detail appears at the rename-to-dispatch boundary: `CtrlBlock` collapses the
per-lane snapshot indication into the head lane before sending the rename window onward
([CtrlBlock.scala:681](src/main/scala/xiangshan/backend/CtrlBlock.scala#L681) to
[CtrlBlock.scala:685](src/main/scala/xiangshan/backend/CtrlBlock.scala#L685)).
That preserves the snapshot event even though dispatch sees the window as a grouped transfer.

### 12.5.3 Redirect, restore, and walk

On redirect, rename immediately stops behaving like a normal frontend-fed stage. The recovery process happens in three
phases, each restoring a different piece of state.

**Phase 1: Block speculative updates.** The first thing rename does is stop making things worse. Speculative RAT writes
are gated by `!io.redirect.valid`, so the wrong-path window does not publish new speculative mappings
([Rename.scala:574](src/main/scala/xiangshan/backend/rename/Rename.scala#L574) to
[Rename.scala:578](src/main/scala/xiangshan/backend/rename/Rename.scala#L578)).
The free lists also suppress normal allocation on redirect
([StdFreeList.scala:92](src/main/scala/xiangshan/backend/rename/freelist/StdFreeList.scala#L92) to
[StdFreeList.scala:95](src/main/scala/xiangshan/backend/rename/freelist/StdFreeList.scala#L95),
[MEFreeList.scala:34](src/main/scala/xiangshan/backend/rename/freelist/MEFreeList.scala#L34) to
[MEFreeList.scala:36](src/main/scala/xiangshan/backend/rename/freelist/MEFreeList.scala#L36)).
This is important: any instructions that were in the rename stage at the time of the redirect must not be allowed to
modify the speculative state, because they are on the wrong path.

**Phase 2: Snapshot selection and state restoration.** `CtrlBlock` chooses whether a saved snapshot can be used. It
flushes invalidated snapshot entries, computes `useSnpt`, and selects the newest surviving snapshot older than the
redirect point
([CtrlBlock.scala:548](src/main/scala/xiangshan/backend/CtrlBlock.scala#L548) to
[CtrlBlock.scala:571](src/main/scala/xiangshan/backend/CtrlBlock.scala#L571)).
The selection logic searches backwards from the most recently created snapshot, looking for the youngest one whose
`robIdx` is older than the redirect target. If no valid snapshot exists (either because none were taken, or all were
taken after the redirect point), recovery falls back to the architectural state.

The actual restore happens inside the state-holding blocks:

- `RenameTable` restores `spec_table` from the selected snapshot or falls back to `arch_table`
  ([RenameTable.scala:137](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L137) to
  [RenameTable.scala:149](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L149)).
- `BaseFreeList` computes a redirected head pointer from the selected snapshot or from `archHeadPtr`, then adds the
  current walk requests so re-rename restarts at the correct place
  ([BaseFreeList.scala:75](src/main/scala/xiangshan/backend/rename/freelist/BaseFreeList.scala#L75) to
  [BaseFreeList.scala:85](src/main/scala/xiangshan/backend/rename/freelist/BaseFreeList.scala#L85)).

**Phase 3: Walk-based rebuild.** After snapshot restore, the speculative state reflects the machine's view at the
snapshot point. But the redirect target may be *after* the snapshot point — there may be correctly speculated
instructions between the snapshot and the misprediction that need their rename effects re-applied. This is what "walk"
accomplishes.

While `io.rabCommits.isWalk` is true, rename stops sending new outputs to dispatch
([Rename.scala:296](src/main/scala/xiangshan/backend/rename/Rename.scala#L296),
[Rename.scala:552](src/main/scala/xiangshan/backend/rename/Rename.scala#L552)).
Instead, the free lists consume `walkReq`, and `RenameTableWrapper` consumes ROB-supplied walk info through its
speculative write ports
([Rename.scala:444](src/main/scala/xiangshan/backend/rename/Rename.scala#L444) to
[Rename.scala:462](src/main/scala/xiangshan/backend/rename/Rename.scala#L462),
[RenameTable.scala:279](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L279) to
[RenameTable.scala:290](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L290)).
The ROB provides the walk information: for each walked instruction, it supplies the logical destination and the
physical destination that was assigned during the original rename. The RAT replays these writes to rebuild the
speculative map, and the free lists advance their head pointers past the physical registers that were allocated.

Once walk completes, the speculative RAT and free-list state match exactly what they would have been if the machine had
only processed the correct-path instructions. Normal rename can then resume from that point.

There is no explicit one-hot FSM register named "rename state" in the RTL. Still, the behavior can be summarized as a
small conceptual state machine:

```mermaid
stateDiagram-v2
  [*] --> Normal

  Normal : accept decode window\nallocate pdest / pdestVl\nwrite speculative RAT
  Normal --> RedirectSeen : redirect.valid
  Normal --> Normal : commit updates arch RAT\nfree reclaimable old tags
  Normal --> Normal : jump fires and snapshot policy allows\ncreate distributed snapshot

  RedirectSeen : block normal speculative writes\nstop normal allocation
  RedirectSeen --> WalkRecovery : rabCommits.isWalk

  WalkRecovery : restore from snapshot or arch state\nconsume walkValid/info\nio.out.valid = 0
  WalkRecovery --> Normal : walk completes
```

**Figure 12.4: Behavioral state view of rename control.** The actual implementation uses distributed gating rather than
one centralized state register, but the effective modes are normal operation, redirect handling, and walk-based rebuild.

## 12.6 Parameterization and Configuration Knobs

Rename is highly parameterized because width, namespace shape, and recovery depth all affect its structures directly.

| Parameter(s) | Default setting | Rename-stage effect |
| ------------ | --------------- | ------------------- |
| [`DecodeWidth`](src/main/scala/xiangshan/Parameters.scala#L80), [`RenameWidth`](src/main/scala/xiangshan/Parameters.scala#L81), [`RabCommitWidth`](src/main/scala/xiangshan/Parameters.scala#L84) | `8`, `8`, `8` by default; `6`, `6`, `6` in `TLBackendV2Config` ([Configs.scala:510](src/main/scala/top/Configs.scala#L510) to [Configs.scala:512](src/main/scala/top/Configs.scala#L512)) | Set the incoming window width, rename bandwidth, and walk/commit replay width that the stage must sustain. |
| [`EnableRenameSnapshot`](src/main/scala/xiangshan/Parameters.scala#L86), [`RenameSnapshotNum`](src/main/scala/xiangshan/Parameters.scala#L87) | `true`, `4` | Control whether distributed rename checkpoints exist and how many can be live at once. |
| [`IntLogicRegs`](src/main/scala/xiangshan/Parameters.scala#L91), [`FpLogicRegs`](src/main/scala/xiangshan/Parameters.scala#L92), [`VecLogicRegs`](src/main/scala/xiangshan/Parameters.scala#L93), [`V0LogicRegs`](src/main/scala/xiangshan/Parameters.scala#L94), [`VlLogicRegs`](src/main/scala/xiangshan/Parameters.scala#L95) | `32`, `34`, `47`, `1`, `1` | Define how many logical names each RAT namespace must cover. |
| [`intPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L116), [`fpPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L122), [`vfPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L128), [`v0Preg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L134), [`vlPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L140) | `224`, `256`, `128`, `22`, `32` | Set the physical pools behind the five rename namespaces. |
| [`MaxUopSize`](src/main/scala/xiangshan/Parameters.scala#L85) | `65` | Sizes rename-side bookkeeping such as `numWB` and worst-case split-uop accounting. |

These parameters fall into three practical buckets.

- **Width parameters** determine how much rename can absorb per cycle. A wider rename means higher peak throughput but
  also a larger bypass network (O(n^2) comparisons for intra-window dependencies).
- **Namespace-shape parameters** determine how many parallel RAT/free-list structures must exist at all. Changing
  the number of logical registers affects RAT table sizes, and changing the number of physical registers affects
  free-list depth and how far ahead the machine can speculate before stalling.
- **Recovery parameters** determine how much speculative state can be checkpointed and how far apart those checkpoints
  are. More snapshots mean faster recovery (less walk distance) but more storage overhead per snapshot.

That grouping matches the real design pressures on the stage: throughput, naming capacity, and recovery latency.

## 12.7 Worked Examples

The mechanisms above are easier to retain when reassembled into complete stories. These examples start with an ordinary
same-window dependency, then move to move elimination, and finally to rename recovery.

### Worked Example 1: `add x8, x1, x2` followed by `addi x9, x8, 1` in the same window

Suppose the speculative RAT currently maps `x1 -> p14`, `x2 -> p37`, `x8 -> p22`. The integer free list's next
available register is `p50`.

1. **RAT reads (launched during decode).** Decode provides two `DecodeOutUop`s and already launched RAT reads for
   `x1`, `x2`, and `x8` through the shared decode-to-rename RAT interface
   ([CtrlBlock.scala:527](src/main/scala/xiangshan/backend/CtrlBlock.scala#L527) to
   [CtrlBlock.scala:531](src/main/scala/xiangshan/backend/CtrlBlock.scala#L531),
   [RenameTable.scala:122](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L122) to
   [RenameTable.scala:156](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L156)).
   The RAT returns `p14` for `x1`, `p37` for `x2`, and `p22` for `x8`.

2. **Destination allocation.** Lane 0 asserts `needIntDest`, requests the integer free list, and receives `p50` as
   its fresh integer physical destination
   ([Rename.scala:438](src/main/scala/xiangshan/backend/rename/Rename.scala#L438) to
   [Rename.scala:443](src/main/scala/xiangshan/backend/rename/Rename.scala#L443),
   [Rename.scala:539](src/main/scala/xiangshan/backend/rename/Rename.scala#L539) to
   [Rename.scala:545](src/main/scala/xiangshan/backend/rename/Rename.scala#L545),
   [MEFreeList.scala:42](src/main/scala/xiangshan/backend/rename/freelist/MEFreeList.scala#L42) to
   [MEFreeList.scala:46](src/main/scala/xiangshan/backend/rename/freelist/MEFreeList.scala#L46)).
   Lane 0's output is: `psrc(0)=p14`, `psrc(1)=p37`, `pdest=p50`.

3. **Same-window bypass.** Lane 1 initially sees the RAT mapping `x8 -> p22`, but `bypassCond` notices that lane 0
   writes the same logical integer register (`ldest=x8`), so lane 1's `psrc(0)` is replaced with lane 0's new
   `pdest` (`p50`)
   ([Rename.scala:680](src/main/scala/xiangshan/backend/rename/Rename.scala#L680) to
   [Rename.scala:727](src/main/scala/xiangshan/backend/rename/Rename.scala#L727)).
   Without this bypass, lane 1 would read the stale value from `p22` instead of the value being produced by lane 0.

4. **ROB index assignment.** Rename emits two physical-tagged uops. Unless ROB compression groups them, lane 0 and
   lane 1 receive consecutive `robIdx` values
   ([Rename.scala:467](src/main/scala/xiangshan/backend/rename/Rename.scala#L467),
   [Rename.scala:552](src/main/scala/xiangshan/backend/rename/Rename.scala#L552)).

5. **Speculative RAT update.** The speculative integer RAT records the new logical-to-physical bindings for younger
   instructions: now `x8 -> p50` (from lane 0's write) and `x9 -> p51` (from lane 1's write, assuming `p51` was the
   next free register)
   ([Rename.scala:574](src/main/scala/xiangshan/backend/rename/Rename.scala#L574) to
   [Rename.scala:578](src/main/scala/xiangshan/backend/rename/Rename.scala#L578)).

This is the common RAW case that any wide rename stage must handle correctly every cycle.

### Worked Example 2: `mv x6, x5`

This case shows what integer move elimination really means in the RTL.

Suppose the speculative RAT currently maps `x5 -> p14` and `x6 -> p30`.

1. **Move detection.** Rename sees `isMove`, so integer destination allocation is suppressed
   ([Rename.scala:399](src/main/scala/xiangshan/backend/rename/Rename.scala#L399) to
   [Rename.scala:402](src/main/scala/xiangshan/backend/rename/Rename.scala#L402),
   [Rename.scala:461](src/main/scala/xiangshan/backend/rename/Rename.scala#L461)).
   The integer free list's `allocateReq` for this lane is `false`, so no physical register is consumed.

2. **No writeback needed.** Because no new physical register is needed, rename sets `numWB := 0`
   ([Rename.scala:470](src/main/scala/xiangshan/backend/rename/Rename.scala#L470) to
   [Rename.scala:472](src/main/scala/xiangshan/backend/rename/Rename.scala#L472)).
   This tells the ROB that this instruction will never produce a writeback event.

3. **Destination becomes source.** The final integer destination tag becomes the physical source tag: `pdest := psrc(0)`,
   which is `p14`
   ([Rename.scala:676](src/main/scala/xiangshan/backend/rename/Rename.scala#L676),
   [Rename.scala:727](src/main/scala/xiangshan/backend/rename/Rename.scala#L727)).
   The speculative RAT now maps `x6 -> p14`. Both `x5` and `x6` point to the same physical register.

4. **Dispatch skips busy marking.** Dispatch does not mark a fresh integer destination busy because it excludes
   move-eliminated uops from integer `allocPregs`
   ([NewDispatch.scala:255](src/main/scala/xiangshan/backend/dispatch/NewDispatch.scala#L255) to
   [NewDispatch.scala:265](src/main/scala/xiangshan/backend/dispatch/NewDispatch.scala#L265)).
   Since `p14` already holds a valid value (from whatever instruction originally wrote `x5`), there is nothing to wait
   for.

5. **Safe freeing at commit.** Later, when commit retires renamed integer mappings, `need_free` duplicate suppression
   ensures the shared physical tag `p14` is not returned to the free list until no committed logical integer name still
   points to it
   ([RenameTable.scala:170](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L170) to
   [RenameTable.scala:174](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L174),
   [Rename.scala:805](src/main/scala/xiangshan/backend/rename/Rename.scala#L805) to
   [Rename.scala:806](src/main/scala/xiangshan/backend/rename/Rename.scala#L806)).
   For example, if a later instruction writes a new value to `x6` and commits, the old `pdest` of `x6` is `p14`. But
   `p14` must not be freed because `x5` still points to it. Only when both `x5` and `x6` have been remapped away from
   `p14` (by later committed writes) will the `need_free` check allow `p14` to return to the free list.

The key idea is that move elimination still changes the naming graph, even though it does not allocate a new physical
register.

### Worked Example 3: A branch that later redirects and uses a rename snapshot

1. **Snapshot creation.** A jump/branch uop fires at rename. If the snapshot-spacing policy is satisfied (at least 32
   ROB positions since the last snapshot), rename marks that uop with `snapshot`
   ([Rename.scala:745](src/main/scala/xiangshan/backend/rename/Rename.scala#L745) to
   [Rename.scala:752](src/main/scala/xiangshan/backend/rename/Rename.scala#L752)).
   At this moment, each free list saves its current `headPtr`, and each RAT saves its current `spec_table`. These
   saved copies are indexed by the snapshot slot number.

2. **Snapshot metadata.** `CtrlBlock` captures the renamed bundle's `robIdx` vector and which lane held the
   control-flow instruction into the central snapshot queue
   ([CtrlBlock.scala:540](src/main/scala/xiangshan/backend/CtrlBlock.scala#L540) to
   [CtrlBlock.scala:544](src/main/scala/xiangshan/backend/CtrlBlock.scala#L544)).
   This metadata allows `CtrlBlock` to later determine whether a given snapshot is older or younger than a redirect
   target.

3. **Normal rename continues.** After the snapshot, suppose 50 more instructions are renamed, consuming physical
   registers and updating the speculative RAT. The snapshot now represents a point 50 instructions in the past.

4. **Redirect arrives.** Much later, a redirect arrives because the branch was mispredicted. `CtrlBlock` flushes
   invalidated snapshot entries and picks the youngest surviving snapshot older than the redirect point; if none
   qualifies, recovery falls back to the architectural state
   ([CtrlBlock.scala:548](src/main/scala/xiangshan/backend/CtrlBlock.scala#L548) to
   [CtrlBlock.scala:571](src/main/scala/xiangshan/backend/CtrlBlock.scala#L571)).
   In this case, the snapshot taken at the branch is valid and is selected.

5. **State restoration.** The RATs restore `spec_table` from the selected snapshot, and the free lists restore their
   speculative heads from the selected snapshot's saved `headPtr`
   ([RenameTable.scala:137](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L137) to
   [RenameTable.scala:149](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L149),
   [BaseFreeList.scala:77](src/main/scala/xiangshan/backend/rename/freelist/BaseFreeList.scala#L77) to
   [BaseFreeList.scala:85](src/main/scala/xiangshan/backend/rename/freelist/BaseFreeList.scala#L85)).
   The speculative state now reflects the machine's view at the time the branch was renamed. All 50 instructions that
   were renamed after the branch are effectively undone. The physical registers they allocated become available again
   (because the free list head was rolled back).

6. **Walk rebuilds remaining state.** During ROB walk, rename stops sending normal outputs and instead consumes walk
   information to rebuild speculative state. If there were correctly speculated instructions between the snapshot point
   and the redirect target (e.g., the branch itself, if it is not flushed), walk replays their rename effects
   ([Rename.scala:289](src/main/scala/xiangshan/backend/rename/Rename.scala#L289) to
   [Rename.scala:296](src/main/scala/xiangshan/backend/rename/Rename.scala#L296),
   [Rename.scala:552](src/main/scala/xiangshan/backend/rename/Rename.scala#L552),
   [RenameTable.scala:279](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L279) to
   [RenameTable.scala:290](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L290)).

This example shows why rename snapshots are valuable: without the snapshot, the machine would have to restore from the
architectural state (potentially hundreds of instructions behind) and walk all the way forward. With the snapshot,
recovery starts from a much closer point, saving potentially dozens of walk cycles.

## 12.8 Design Trade-off

> **Design Trade-off: Pipelined RAT Read, Extra Local Bypass**
>
> XiangShan does not put all rename functionality into one giant combinational "read RAT, allocate pdest, bypass,
> update RAT" path. Instead, `RenameTable` makes the main array read synchronous and adds explicit write bypass
> ([RenameTable.scala:122](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L122) to
> [RenameTable.scala:156](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L156)). That shortens the
> central table timing path and scales better to a wide rename window.
>
> The cost is that the stage must recover the lost immediacy elsewhere. Decode must launch RAT reads one cycle before
> rename consumes them
> ([CtrlBlock.scala:527](src/main/scala/xiangshan/backend/CtrlBlock.scala#L527) to
> [CtrlBlock.scala:531](src/main/scala/xiangshan/backend/CtrlBlock.scala#L531)),
> and rename must add a second layer of same-window bypass to repair younger uops that depend on older lanes'
> just-allocated destinations
> ([Rename.scala:655](src/main/scala/xiangshan/backend/rename/Rename.scala#L655) to
> [Rename.scala:727](src/main/scala/xiangshan/backend/rename/Rename.scala#L727)).
>
> The alternative would be a purely combinational RAT: present the address, get the data in the same cycle, bypass
> same-cycle writes combinationally. This is simpler conceptually but creates a long critical path: RAT read + bypass
> mux + free-list allocation + intra-window bypass + RAT write must all complete within one clock period. For a narrow
> 2-wide machine, that might be acceptable. For XiangShan's 8-wide rename, the combinational depth would be a
> frequency limiter.
>
> Integer move elimination makes that trade-off sharper: the final `pdest` of a move may itself depend on a bypassed
> `psrc`, creating a chain of dependent muxes that extends the critical path. The comments in the RTL at
> [Rename.scala:655](src/main/scala/xiangshan/backend/rename/Rename.scala#L655) to
> [Rename.scala:674](src/main/scala/xiangshan/backend/rename/Rename.scala#L674) describe this dependency chain
> explicitly. XiangShan chooses explicit local logic and pipelined tables over a slower monolithic rename array. The
> result is more nuanced timing, but a more scalable wide rename implementation.

## 12.9 Key Takeaways

- XiangShan rename converts decoded logical uops into speculative physical-tagged backend work and is therefore the
  true dependency-naming boundary between decode and dispatch.
- The current RTL renames five namespaces: integer, floating-point, vector, `v0`, and `vl`. Integer rename is special
  because it supports move elimination and duplicate-aware freeing.
- RAT reads are pipelined rather than purely combinational. Correct same-cycle behavior is recovered through explicit
  RAT write bypass plus a second same-window `pdest -> psrc` bypass network in rename.
- Rename also owns compression-aware `robIdx` assignment and snapshot generation, so the stage controls both register
  naming and part of the machine's speculative recovery naming.
- Precise recovery comes from keeping speculative RAT state, free-list state, and ROB position aligned through commit,
  snapshot restore, and walk.

## 12.10 Checkpoint Questions

1. **Basic.** What is the difference between the speculative RAT and the architectural RAT in XiangShan?
2. **Basic.** Why does current Kunminghu rename maintain separate `v0` and `vl` rename namespaces instead of folding
   them into the ordinary vector namespace?
3. **Intermediate.** Why does `RenameTable` use synchronous reads with explicit bypass instead of a purely
   combinational RAT lookup?
4. **Intermediate.** How does same-window bypass let lane `i+1` consume the new `pdest` produced by lane `i` in the
   same rename cycle?
5. **Intermediate.** Why can an integer move-eliminated instruction still change rename state even though it allocates
   no new physical register?
6. **Advanced.** Why does integer freeing need `need_free` duplicate suppression, while FP/vector freeing can use a
   simpler rule?
7. **Advanced.** Explain why rename, not dispatch, owns compression-aware `robIdx` assignment in XiangShan.
8. **Advanced.** How do redirect, snapshot restore, and ROB walk cooperate to rebuild rename state after a
   misprediction?

## 12.11 Further Reading

1. [Rename.scala](src/main/scala/xiangshan/backend/rename/Rename.scala#L1) for the top-level rename data path,
   allocation rules, same-window bypass, snapshot policy, and commit/free logic.
2. [RenameTable.scala](src/main/scala/xiangshan/backend/rename/RenameTable.scala#L1) for the speculative/architectural
   RAT structure, synchronous read timing, and old-tag reclamation logic.
3. [BaseFreeList.scala](src/main/scala/xiangshan/backend/rename/freelist/BaseFreeList.scala#L1),
   [StdFreeList.scala](src/main/scala/xiangshan/backend/rename/freelist/StdFreeList.scala#L1), and
   [MEFreeList.scala](src/main/scala/xiangshan/backend/rename/freelist/MEFreeList.scala#L1) for namespace-specific
   allocation, freeing, and recovery.
4. [CompressUnit.scala](src/main/scala/xiangshan/backend/rename/CompressUnit.scala#L1) for ROB-compression grouping and
   `needRobFlags` generation.
5. [CtrlBlock.scala](src/main/scala/xiangshan/backend/CtrlBlock.scala#L527) and
   [Rename.md](XiangShan-Design-Doc/docs/zh/backend/CtrlBlock/Rename.md#L1) for stage integration, snapshot selection,
   and the design note that complements the RTL.
