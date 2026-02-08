# Chapter 6. Why Processors Need a Fetch Target Queue

Chapter 5 explained how branch prediction solves the pipeline's fundamental uncertainty: where to
fetch next. But prediction is only the beginning of the problem. Once the predictor guesses a fetch
target, that target must flow through a pipeline of consumers — instruction cache, instruction fetch
unit, backend execution — each operating at different speeds and with different failure modes. When
any of these consumers discovers that the prediction was wrong, all speculative work downstream must
be discarded and the pipeline restarted.

This chapter introduces the **Fetch Target Queue (FTQ)**, the structure that manages this complexity.
No prior microarchitecture knowledge is assumed beyond what was covered in Chapters 4 and 5.

### ASCII Mental Model (Read This First)

```text
Without FTQ:                              With FTQ:

  BPU ──────> IFU ──────> Backend           BPU ──> FTQ ──> IFU ──> Backend
              ↑             │                 ↑       │       ↑       │
              └─────────────┘                 │       │       │       │
          redirect (tight coupling)           └───────┴───────┴───────┘
                                              redirect/resolve/commit
                                              (decoupled, ordered)

  BPU must wait for IFU to be ready.        BPU writes into FTQ independently.
  Redirect wiring is ad-hoc.                FTQ manages all speculation state.
  Training data has no home.                FTQ stores metadata for recovery
                                            and training.
```

If you remember only one thing from this chapter: **the FTQ turns a tangle of point-to-point
handshakes between prediction, fetching, and correction into an orderly queue with clear ownership
of speculation state.**

---

## 6.1 The Decoupling Problem

### 6.1.1 Producer and Consumer Speed Mismatch

The branch predictor is fast. A well-designed BPU can produce a new fetch target every cycle — in
Kunminghu, the fast predictor layer delivers a target in a single cycle (Chapter 5, Section 5.9.3).
But downstream consumers cannot always keep up:

- **Instruction cache** may miss, stalling for tens of cycles while data is fetched from L2 or
  main memory.
- **Instruction fetch unit** may be busy processing the previous fetch block, checking
  cross-page boundary conditions, or servicing an uncached/MMIO-mapped instruction fetch.
- **Backend** may stall on a long-latency operation, causing backpressure that propagates forward.

Without buffering, the BPU would stall whenever any downstream consumer is not ready. Every cycle
the BPU stalls is a cycle where it cannot look ahead and predict future control flow — reducing the
effective pipeline depth the processor can sustain.

### 6.1.2 The Feedback Speed Mismatch

The mismatch works in the other direction too. When the backend discovers a misprediction or the
IFU detects an inconsistency, a **redirect** must reach the BPU and restart prediction from the
correct address. But redirect information arrives at unpredictable times:

- A branch misprediction might be detected 10–20 cycles after prediction.
- An instruction page fault might arrive even later.
- An IFU-level pre-decode check might detect an error within a few cycles.

Each of these events must invalidate some speculative work, but the amount of work to invalidate
depends on *how far ahead* the BPU has run since the mispredicted instruction was predicted. Without
a structure to track which predictions are still speculative and which have been confirmed,
correctness is very hard to maintain.

### 6.1.3 Why Simple Wiring Fails

Consider the naive approach: connect BPU directly to IFU, and route redirects directly from backend
to BPU. This creates several problems:

1. **BPU stalls on IFU backpressure.** If ICache misses, BPU cannot predict ahead. The processor
   loses its ability to build a prefetch pipeline.

2. **No ordered tracking of speculation.** When a redirect arrives, the processor needs to know
   exactly which predictions to discard. Without an ordered log of speculative decisions, this
   requires expensive tag-matching or flush-everything strategies.

3. **No metadata storage for recovery.** To restart prediction correctly after a redirect, the BPU
   needs to restore internal state (global history register, RAS pointer) to what it was at the
   mispredicted branch. This state must be saved somewhere when the prediction is made.

4. **No metadata storage for training.** To improve future predictions, the BPU needs to know the
   actual outcome of each branch and the predictor state that was used to make the original
   prediction. This requires per-prediction storage that persists until the branch resolves.

All four problems point to the same solution: insert a queue between prediction and consumption
that stores both the predicted targets and the metadata needed for recovery and training.

---

## 6.2 The Fetch Target Queue Concept

### 6.2.1 Definition

A **Fetch Target Queue** is a hardware structure that sits between the branch predictor and the
instruction fetch pipeline. Each entry in the FTQ records:

- The **fetch target**: a starting PC and the predicted control-flow boundary (where the next
  taken branch ends the fetch block).
- **Recovery metadata**: predictor internal state (history registers, RAS state) at the time of
  prediction, needed to restore the BPU if this prediction turns out to be wrong.
- **Training metadata**: predictor table indices, counter values, and tag information needed to
  update the predictor tables when the actual branch outcome becomes known.

The FTQ was first proposed by Reinman, Austin, and Calder (ISCA 1999) as a mechanism to decouple
branch prediction from instruction fetching. Their insight was that allowing the predictor to "run
ahead" of the fetch unit — storing predictions in a queue until the fetch unit is ready to consume
them — improves both throughput and the effectiveness of instruction prefetching.

### 6.2.2 The Conveyor Belt Analogy

Think of the FTQ as a conveyor belt in a factory:

```text
  ┌─────────────────────────────────────────────────────────────────┐
  │                        FTQ (conveyor belt)                      │
  │                                                                 │
  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐             │
  │  │ Entry 3 │  │ Entry 2 │  │ Entry 1 │  │ Entry 0 │             │
  │  │ target  │  │ target  │  │ target  │  │ target  │             │
  │  │ + meta  │  │ + meta  │  │ + meta  │  │ + meta  │             │
  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘             │
  │       ↑                                       ↓                 │
  │   BPU writes                            IFU consumes            │
  │   (fast)                                (at its own pace)       │
  └─────────────────────────────────────────────────────────────────┘
              ↑                                       │
          redirect                               fetch request
         (rewind)                               (to ICache/IFU)
```

The BPU places packages (fetch targets + metadata) onto the belt. The IFU picks them off at its own
pace. If the IFU is slow (cache miss), the belt accumulates entries — the BPU keeps predicting
ahead. If a redirect arrives, the belt is partially rewound: entries after the mispredicted point
are discarded, and the BPU restarts from the corrected target.

The key insight is that the "packages" carry not just the fetch address, but also "receipts" — the
metadata needed to undo or learn from the speculation. Losing either the package or the receipt
breaks either performance or correctness.

### 6.2.3 Two Kinds of Fetch Request

The ICache in Kunminghu uses a two-phase access pipeline, and the FTQ drives each phase through
a separate request type issued at different times by different pointers:

- A **prefetch request** initiates the first phase of an ICache access: address translation
  (TLB lookup), tag comparison, and — if the cache line is absent — a fill request to bring data
  from lower memory levels. It also records which cache way holds the data so that the later fetch
  phase can read the correct way without repeating the tag check. Critically, the prefetch phase
  does *not* read instruction data or deliver anything to the IFU — its job is to prepare the
  cache and its lookup metadata so the subsequent fetch can proceed quickly. The FTQ's prefetch
  pointer (`pfPtr`) tracks which entries have had their prefetch requests issued.

- A **fetch request** (sometimes called a *full fetch request*) initiates the second phase: using
  the way lookup information prepared by the prefetch phase, it reads the cache data arrays and
  delivers the instruction bytes to the Instruction Fetch Unit (IFU) for pre-decode, alignment,
  and further processing. Because the prefetch phase has already handled translation and tag
  checking, the fetch phase can focus on data retrieval and delivery. The FTQ's IFU pointer
  (`ifuPtr`) tracks which entries have had their fetch requests issued.

Because the prefetch pointer runs ahead of the IFU pointer, the first phase (translation, tag
check, miss fill) is typically complete by the time the fetch request arrives — allowing the
second phase to read data immediately rather than stalling. Section 6.8 discusses this mechanism
in more detail, and Chapter 7 covers the ICache's two-phase pipeline architecture.

### 6.2.4 Key Terminology

These terms recur throughout the FTQ chapters:

| Term | Definition |
| --- | --- |
| **Fetch target** | A predicted fetch-block starting PC plus the predicted control-flow endpoint within that block (e.g., the position of the first taken branch). |
| **FTQ entry** | One slot in the queue, holding a fetch target and associated metadata. |
| **Speculation ledger** | A structure that records speculative decisions in program order, enabling selective invalidation and state recovery. The FTQ serves this role for the frontend. |
| **Enqueue** | The act of the BPU writing a new prediction into the next available FTQ slot. |
| **Redirect** | A control-flow correction that invalidates one or more FTQ entries and rewinds the prediction stream. |
| **Resolve** | The backend determining the actual outcome (direction and target) of a branch instruction. |
| **Commit** | The backend confirming that an instruction has retired and its effects are architecturally visible. |
| **Runahead** | The distance (in entries or cycles) between the BPU's current prediction and the IFU's current fetch — how far ahead the predictor has run. |

---

## 6.3 Multi-Pointer Queue Organization

### 6.3.1 Why Not a Simple FIFO?

A standard FIFO queue has two pointers: a write pointer (tail) and a read pointer (head). The
producer writes at the tail, the consumer reads at the head, and each pointer advances
independently. This works well when there is one producer and one consumer, and consumption is
strictly ordered.

The FTQ has a more complex lifecycle. Each entry passes through several stages, and different
downstream agents need to interact with entries at different points:

1. **BPU writes** a new entry (the prediction).
2. **Prefetch logic reads** the entry and sends a prefetch request to the ICache, initiating
   address translation, tag lookup, and potential cache fill (Section 6.2.3).
3. **IFU reads** the entry and sends a fetch request to the ICache, which reads the data arrays
   and delivers instruction bytes to the IFU for processing (Section 6.2.3).
4. **Backend resolves** branch outcomes for the entry's instructions.
5. **Backend commits** the entry's instructions, confirming they are architecturally correct.

Each of these stages can stall independently. The prefetch might race ahead of the IFU. The IFU
might stall on a cache miss while the BPU continues predicting. The backend might resolve branches
out of order but commit them in order.

### 6.3.2 The Multi-Pointer Design

The solution is to use multiple pointers, each tracking a different stage of an entry's lifecycle:

```text
  FTQ entries:  [ 0 ] [ 1 ] [ 2 ] [ 3 ] [ 4 ] [ 5 ] [ 6 ] [ 7 ] ...
                  ↑                   ↑           ↑           ↑
               commitPtr           ifuPtr       pfPtr       bpuPtr
               (next                (next        (next       (next
                to commit)          to fetch)    to prefetch) to predict)
```

- **`bpuPtr`** (write pointer): the next slot the BPU will write into. Advances when a new
  prediction is accepted.
- **`pfPtr`** (prefetch pointer): the next entry to be sent as a prefetch request to the ICache.
  Advances when the prefetch request fires.
- **`ifuPtr`** (fetch pointer): the next entry to be sent as a fetch request to IFU and ICache.
  Advances when the fetch request fires.
- **`commitPtr`** (commit pointer): the oldest entry not yet retired by the backend. Advances as
  the backend commits instructions.

The invariant is: `commitPtr ≤ ifuPtr ≤ pfPtr ≤ bpuPtr` (using circular comparison). Each pointer
advances on its own handshake, so:

- The BPU can run ahead of the IFU by up to `bpuPtr - ifuPtr` entries.
- The prefetch logic can run ahead of the IFU by up to `pfPtr - ifuPtr` entries (typically just 1).
- Committed entries can be reclaimed because no future operation will reference them.

### 6.3.3 Circular Buffer Semantics

Like most hardware queues, the FTQ uses modular arithmetic on its pointers. With `N` entries, each
pointer is `log2(N) + 1` bits wide (the extra bit distinguishes "full" from "empty" when the low
bits wrap around). The queue is full when `bpuPtr` catches up to `commitPtr` from behind; it is
empty when all pointers are equal.

### 6.3.4 Pointer Timeline Example

Consider a steady-state scenario with an 8-entry FTQ:

```text
  Time T0:   commitPtr=2  ifuPtr=4  pfPtr=5  bpuPtr=6
             entries 2-5 are in-flight (predicted but not all committed)
             entry 6 is being written by BPU this cycle

  Time T1:   commitPtr=3  ifuPtr=5  pfPtr=6  bpuPtr=7
             commit advanced (entry 2 retired), fetch/prefetch/predict advanced

  Time T2:   commitPtr=3  ifuPtr=5  pfPtr=6  bpuPtr=7
             ICache miss! ifuPtr stalls. BPU could still advance if allowed.

  Time T3:   commitPtr=3  ifuPtr=5  pfPtr=7  bpuPtr=0 (wrapped)
             BPU continues predicting; prefetch advances; IFU still stalled
```

This shows the decoupling in action: the BPU has wrapped around past entry 7 to entry 0, while the
IFU is stuck waiting for the ICache to respond for entry 5.

---

## 6.4 Runahead: How Far Ahead Can the Predictor Run?

### 6.4.1 The Runahead Distance

The distance between `bpuPtr` and `ifuPtr` is called the **runahead distance**. A larger runahead
means more predictions are buffered and ready for the IFU when it becomes available — reducing the
chance that the IFU starves for targets after a cache miss resolves.

Runahead also enables **fetch-directed instruction prefetching** (Reinman et al., MICRO 1999): the
prefetch pointer can issue cache line prefetches for predicted targets before the IFU needs them,
turning cold cache misses into warm hits.

### 6.4.2 Runahead Must Be Bounded

Unlimited runahead would be wasteful and potentially harmful:

1. **Queue capacity**: The FTQ has a fixed number of entries. If the BPU fills the entire queue
   while the IFU is stalled, no more predictions can be accepted until entries are freed by commits.

2. **Speculation depth**: Every entry in the FTQ represents speculative work. On a misprediction,
   all entries between the mispredicted entry and `bpuPtr` are discarded. Deep runahead means more
   wasted work on a misprediction — and importantly, more training metadata that was stored
   uselessly.

3. **Training pressure**: If the BPU runs too far ahead, the resolve/commit feedback for earlier
   entries may back up. The FTQ must feed training data back to the BPU, and if this channel is
   backpressured (the BPU cannot accept training updates fast enough), new predictions may need to
   be throttled anyway.

For these reasons, practical FTQ designs bound the runahead distance. A typical bound is 8–16
entries beyond the IFU pointer. This provides enough buffering to cover a moderate cache miss
without excessive speculation depth.

### 6.4.3 Backpressure Mechanism

When the runahead limit is reached, the FTQ signals the BPU that it is not ready to accept more
predictions. The BPU stalls its pipeline until the IFU advances (consuming an entry and reducing
the distance) or entries are freed by commits.

This backpressure is the FTQ's way of telling the BPU: "slow down, you have predicted far enough
ahead — let the rest of the pipeline catch up before speculating further."

---

## 6.5 The Speculation Ledger: Recovery and Redirect

### 6.5.1 What Happens on a Misprediction

When the backend resolves a branch and discovers that the BPU's prediction was wrong, the processor
must:

1. **Flush speculative work**: All instructions fetched on the wrong path must be discarded.
   In FTQ terms, all entries between the mispredicted entry and `bpuPtr` are invalidated.

2. **Rewind pointers**: `bpuPtr`, `pfPtr`, and `ifuPtr` are all reset to point just past the
   mispredicted entry. The BPU will restart prediction from the corrected target address.

3. **Restore predictor state**: The BPU's global history register, RAS pointer, and any other
   speculative state must be restored to what they were at the mispredicted branch. Without this,
   future predictions would use a corrupted history.

```text
  Before redirect:
    commitPtr=2  ifuPtr=5  pfPtr=7  bpuPtr=9
    Entry 4 is mispredicted.

  After redirect:
    commitPtr=2  ifuPtr=5  pfPtr=5  bpuPtr=5
    Entries 5-9 are flushed.
    BPU restarts from corrected target.
    ifuPtr, pfPtr, bpuPtr all rewind to entry 5.
```

### 6.5.2 Why FTQ Stores Recovery Metadata

The key requirement for correct recovery is that the BPU can restore its internal state to the
point of the mispredicted branch. This requires saving a snapshot of relevant BPU state at
prediction time.

For example:
- **Global History Register (GHR)**: The TAGE predictor indexes its tables using a hash of the
  branch PC and the GHR. If the GHR is not restored correctly, all subsequent predictions after
  recovery will use wrong indices and produce poor accuracy.
- **Path History Register (PHR)**: Similar to GHR but records target addresses instead of
  taken/not-taken bits. Also needs restoration.
- **RAS state**: The Return Address Stack top pointer must be restored, or return predictions
  after recovery will be wrong.

These snapshots are stored in the FTQ alongside each prediction. When a redirect occurs, the FTQ
reads the recovery metadata from the mispredicted entry and sends it to the BPU along with the
corrected target address.

### 6.5.3 Redirect Sources

Conceptually, frontend redirection comes from three places:

| Path | Typical trigger | Role in recovery |
| --- | --- | --- |
| BPU late correction (`s3 override`) | A slower predictor stage disagrees with an earlier fast prediction | Fast local correction inside the prediction/fetch side; reduces wasted work early |
| IFU consistency check | Predecode/fetch logic finds prediction inconsistency | Frontend requests a restart from a corrected boundary before backend resolution |
| Backend redirect | Executed result proves prediction wrong, or execution raises trap/exception/memory-order recovery | Architecturally authoritative correction point |

A useful way to think about priority is:

1. Backend redirects are authoritative and therefore dominate external frontend corrections.
2. IFU redirects are earlier frontend-detected corrections and are valuable for reducing wrong-path
   fetch.
3. BPU late correction is a local refinement path; it improves timeliness but is still speculative
   and can be superseded by later, more authoritative signals.

Within backend redirects, different causes (mispredict, trap/exception, memory replay) are unified
into one ordered recovery stream so the machine always rolls back to a single well-defined point.

---

## 6.6 The Training Bridge: FTQ Enables Predictor Learning

### 6.6.1 Why Training Requires FTQ

Chapter 5 (Section 5.11) explained that predictors improve through a learning loop: predict, verify,
and update tables based on the actual outcome. But there is a timing gap:

- The prediction is made in the BPU pipeline (cycle N).
- The actual outcome is determined when the backend resolves the branch (cycle N + 10–20).
- The predictor update needs both the outcome *and* the original prediction context (which table
  was used, what the counter values were, what history was in play).

Without the FTQ, this information would need to travel through the entire pipeline alongside the
instruction — adding wires and complexity to every pipeline stage. The FTQ provides a cleaner
solution: store the prediction context at enqueue time, and look it up when the outcome arrives.

### 6.6.2 Two Training Timescales

Branch outcomes become available at two different points:

1. **At resolve time**: when the backend executes the branch and determines its actual direction
   and target. This is the earliest moment the predictor can learn. Resolve-time training provides
   fast feedback but is still speculative — the resolving instruction has not yet committed.

2. **At commit time**: when the branch instruction retires from the reorder buffer. This is
   architecturally definitive — the branch is known to be on the correct path. Commit-time
   training is safe but delayed.

Different predictor components may train at different times:
- Direction predictors (TAGE, SC) can train at resolve time for fast learning.
- RAS updates should train at commit time to avoid corrupting the architectural call stack with
  speculative calls that are later flushed.

The FTQ must store separate metadata for each training timescale, since the information needed
differs (direction/target outcome vs. call/return stack actions).

### 6.6.3 Training Bandwidth

The backend may resolve multiple branches per cycle (in a wide out-of-order machine, several branch
instructions can execute simultaneously). The BPU training port, however, typically has limited
bandwidth — it can process one or a few training updates per cycle.

This creates a producer-consumer mismatch analogous to the prediction-fetch mismatch. The FTQ (or
associated resolve/commit queues) must buffer training events and feed them to the BPU at a
sustainable rate. If training falls behind, the FTQ may need to throttle new predictions to prevent
the training queue from overflowing.

---

## 6.7 FTQ Entry Lifecycle

Combining all the concepts above, each FTQ entry goes through a well-defined lifecycle governed
entirely by pointer positions. Four pointers — `bpuPtr`, `pfPtr`, `ifuPtr`, `commitPtr` — carve
the circular queue into regions, and an entry's "state" is determined by which pointers have passed
it.

### 6.7.1 The Happy Path

When no misprediction occurs, an entry advances through four stages:

```text
  ┌──────┐   BPU writes   ┌───────────┐  pfPtr fires  ┌────────────┐
  │ Free │ ─────────────> │ Predicted │ ────────────> │ Prefetched │
  └──────┘  (bpuPtr       └───────────┘               └────────────┘
             advances)                                       │
                                                        ifuPtr fires
                                                             │
       entry freed                                           v
       (slot reusable          ┌───────────┐          ┌───────────┐
        by bpuPtr)             │ Committed │ <─────── │ Fetched   │
                               └───────────┘  commit  └───────────┘
            ^                        │        drains
            └────────────────────────┘
```

1. **Free → Predicted.** The BPU writes a new prediction (start PC, taken-branch offset,
   recovery metadata, training metadata) into the slot that `bpuPtr` points to, then advances
   `bpuPtr`. The entry now holds speculative data.

2. **Predicted → Prefetched.** The prefetch pointer `pfPtr` reads the entry's start PC and sends
   a prefetch request to the ICache, then advances. The ICache can begin filling the line before
   the actual fetch arrives.

3. **Prefetched → Fetched.** The IFU pointer `ifuPtr` reads the entry and issues a real fetch
   request (to both ICache and IFU simultaneously), then advances. The IFU retrieves the
   instruction bytes, performs pre-decode checks, and passes the fetch block downstream to the
   backend.

4. **Fetched → Committed.** When the backend's reorder buffer retires the instructions that
   belong to this entry, it sends a commit notification carrying the entry's FTQ index. The FTQ
   captures this into an internal "ROB commit pointer" (`robCommitPtr`). Then `commitPtr` advances
   one entry per cycle until it catches up with `robCommitPtr`, freeing each entry it passes.
   This drain-one-per-cycle design avoids a wide comparator but means that commit deallocation
   may take several cycles when the backend retires a burst of entries at once.

### 6.7.2 The Flush Path

A redirect (from the backend on misprediction/exception, or from the IFU on a pre-decode error)
can flush an entry that is in **any** speculative stage — Predicted, Prefetched, or Fetched:

```text
              ┌───────────┐
              │ Predicted │ ───┐
              └───────────┘    │
              ┌────────────┐   │  redirect arrives:
              │ Prefetched │ ──┤  all three speculative pointers
              └────────────┘   │  (bpuPtr, pfPtr, ifuPtr) snap
              ┌───────────┐    │  back to the corrected entry
              │ Fetched   │ ───┘
              └───────────┘
                    │
                    v
              ┌──────────┐     pointer rewind     ┌──────┐
              │ Flushed  │ ────────────────────>  │ Free │
              └──────────┘                        └──────┘
```

When a redirect fires, `bpuPtr`, `pfPtr`, and `ifuPtr` are all reset to the corrected entry index.
Every entry between that index and the old `bpuPtr` is implicitly invalidated — no per-entry valid
flag needs to be cleared, because the entry falls outside the active pointer window. The `commitPtr`
is never rewound; it tracks only non-speculative, architecturally committed state.

### 6.7.3 Training Is a Side-Band Process

The lifecycle diagram above shows the stages tracked by the FTQ's main pointers. Training the
branch predictor — resolve-time training and commit-time training (Section 6.6) — does **not**
appear as a stage in this sequence. Instead, training is handled by separate side-band queues
(a resolve queue and a commit queue) with their own internal pointers. These queues buffer
training events and drain them to the BPU independently of the main entry lifecycle.

An entry does not wait to be "trained" before it can be committed and freed. Training and commit
proceed in parallel through separate paths. If a redirect invalidates an entry before its training
data drains, the side-band queue marks the event as flushed and skips it.

### 6.7.4 Implicit State — No Per-Entry Flags

This lifecycle is not encoded as an explicit state machine. There are no per-entry "valid,"
"committed," or "trained" flags. Instead, the state emerges entirely from pointer positions:

- An entry at index *i* is **allocated** if it falls between `commitPtr` and `bpuPtr`.
- It is **awaiting prefetch** if it falls between `pfPtr` and `bpuPtr`.
- It is **awaiting fetch** if it falls between `ifuPtr` and `bpuPtr`.
- It is **committed** once `commitPtr` has advanced past it.

This pointer-based design is elegant and efficient: flushing dozens of speculative entries requires
no per-entry writes — just moving three pointers. The cost is that the "state" of any single entry
is not directly readable; it must be inferred from the relative positions of the pointers.

---

## 6.8 FTQ and Instruction Prefetching

### 6.8.1 Fetch-Directed Prefetching

One of the most powerful benefits of the FTQ is its ability to drive instruction prefetching. Since
the BPU can predict several targets ahead of the IFU, the FTQ knows the addresses that will be
fetched in the near future. By issuing prefetch requests for these addresses to the ICache, the FTQ
can convert cold cache misses into warm cache hits.

```text
                       entries waiting to be fetched
                       (predicted but not yet requested)
                            │
  ┌───────┐  ┌───────┐  ┌──┴────┐  ┌───────┐  ┌───────┐
  │ E(n)  │  │ E(n+1)│  │ E(n+2)│  │ E(n+3)│  │ E(n+4)│
  └───────┘  └───────┘  └───────┘  └───────┘  └───────┘
      ↑           ↑          ↑          ↑          ↑
   commitPtr   ifuPtr     pfPtr                 bpuPtr

   IFU is fetching E(n+1).
   Prefetch logic sends E(n+2)'s address to ICache.
   E(n+3) and E(n+4) are predicted but will be prefetched soon.
```

The prefetch pointer (`pfPtr`) runs ahead of the IFU pointer, issuing prefetch requests for entries
that the IFU will request shortly. This gives the ICache time to bring data into the cache before
the actual fetch request arrives.

### 6.8.2 Prefetch Accuracy

Because the prefetch targets come from the BPU's predictions, their accuracy depends on prediction
accuracy. Mispredicted targets lead to **useless prefetches** that waste cache bandwidth and may
pollute the cache. However, since modern BPUs achieve 95%+ accuracy, most prefetches are useful —
and the performance benefit of turning cache misses into hits far outweighs the cost of occasional
wasted prefetches.

---

## 6.9 Design Trade-Offs

### 6.9.1 FTQ Size

The number of FTQ entries determines how much speculation the processor can buffer:

- **Too small**: The BPU frequently stalls because the queue fills up before the IFU drains it.
  This reduces the effective runahead and prefetch window.
- **Too large**: Excessive entries waste silicon area on metadata storage that is rarely used. On a
  misprediction, more entries must be flushed, and the training queues see more stale data.

Typical high-performance designs use 32–64 entries, balancing runahead depth against area cost.

### 6.9.2 Metadata Granularity

Each FTQ entry must store recovery and training metadata. The amount of metadata per entry is a
significant design decision:

- **Minimal metadata** (just PC and target): Small entries, but recovery requires recomputing
  predictor state — adding latency and complexity to the redirect path.
- **Full metadata** (GHR snapshot, RAS snapshot, table indices, counter values): Large entries, but
  recovery is fast and training is straightforward.
- **Split metadata**: Store different metadata classes in separate arrays, written and read at
  different times. This reduces port pressure on any single array but adds routing complexity.

### 6.9.3 Single Queue vs. Split Queues

A design can use one monolithic FTQ that stores everything, or split the function across multiple
coordinated queues:

- **Single queue**: Simpler control logic, one set of pointers. But all metadata must be written
  at enqueue and read at various times, creating port contention.
- **Split queues**: Separate structures for prediction data, redirect recovery metadata, resolve
  training metadata, and commit training metadata. Each can be optimized independently, but pointer
  coordination and flush logic become more complex.

### 6.9.4 Override Handling

When the accurate BPU layer (s3) disagrees with the fast layer (s1), it produces a late correction.
The FTQ must handle this by overwriting the earlier entry with the corrected prediction. This
**override** mechanism is simpler than a full redirect — it does not involve the backend — but it
still requires the FTQ to support out-of-order writes to earlier entries while the BPU continues
enqueuing new ones.

---

## 6.10 Worked Example: FTQ Through a Misprediction

To bring these concepts together, let us trace the FTQ's behavior through a complete misprediction
scenario.

**Setup**: The FTQ has 8 entries. The BPU has predicted entries 0 through 5.

| Cycle | Event | Pointer State |
| --- | --- | --- |
| C0 | BPU predicts entry 6. FTQ stores target + metadata. | commit=0, ifu=2, pf=4, bpu=7 |
| C1 | IFU fetches entry 2. Prefetch issues for entry 4. | commit=0, ifu=3, pf=5, bpu=7 |
| C2 | Backend resolves entry 1: branch was mispredicted. | commit=0, ifu=3, pf=5, bpu=7 |
| C3 | FTQ receives redirect for entry 1. Reads recovery metadata from entry 1. Computes corrected target. Rewinds pointers. | commit=0, ifu=2, pf=2, bpu=2 |
| C4 | FTQ sends redirect + metadata to BPU. BPU restores GHR/PHR/RAS from saved snapshot. | commit=0, ifu=2, pf=2, bpu=2 |
| C5 | BPU predicts from corrected target, writes entry 2. | commit=0, ifu=2, pf=2, bpu=3 |
| C6 | Normal operation resumes. Prefetch and IFU advance. | commit=1, ifu=3, pf=3, bpu=4 |

Key observations:
- Entries 2–6 were flushed in cycle C3. The speculative work they represented is discarded.
- The recovery metadata saved in entry 1 at prediction time (cycle before C0) enabled the BPU to
  restore its state correctly in cycle C4.
- The IFU pointer rewound to entry 2 — the entry after the mispredicted one — because the IFU will
  re-fetch from the corrected target.

---

## 6.11 FTQ in the Broader Pipeline Context

### 6.11.1 Connection to Chapter 5 (BPU)

The BPU is the FTQ's sole producer. Everything the FTQ stores originates from BPU predictions. The
FTQ feeds back to the BPU in three ways:

1. **Redirect** (on misprediction): corrected target + recovery metadata.
2. **Resolve training** (on branch resolution): actual outcome + original prediction context.
3. **Commit training** (on instruction retirement): commit-time events like call/return for RAS
   architectural updates.

### 6.11.2 Connection to Chapter 7 (ICache) and Chapter 8 (IFU)

The FTQ is the primary driver of fetch requests. ICache and IFU do not decide *what* to fetch —
they receive fetch targets from the FTQ and process them. The FTQ also drives prefetch requests to
the ICache.

On the feedback side, the IFU can detect prediction inconsistencies (through pre-decode checks) and
send redirects back to the FTQ, which handles them using the same redirect machinery used for
backend corrections.

### 6.11.3 Connection to the Backend

The backend interacts with the FTQ through three channels:

1. **Redirect**: when a branch misprediction, exception, or memory ordering violation is detected.
2. **Resolve**: when branch outcomes become known, providing training data.
3. **Commit**: when instructions retire, advancing the commit pointer and providing commit-time
   training events.

The FTQ also writes fetch target PCs into a backend-visible storage (PC memory) so that the backend
can use them for exception handling and redirect target computation.

---

## Key Takeaways

- The FTQ decouples the BPU from the IFU, allowing the predictor to run ahead and buffer fetch
  targets even when downstream consumers stall.
- Each FTQ entry stores not just a fetch target (PC + control-flow endpoint) but also recovery
  metadata (for redirect) and training metadata (for predictor updates).
- Multiple pointers (`bpuPtr`, `pfPtr`, `ifuPtr`, `commitPtr`) track different stages of each
  entry's lifecycle, advancing independently on different handshakes.
- Runahead is bounded to limit speculation depth, wasted work on mispredictions, and training queue
  pressure.
- The FTQ is the central coordination point for all frontend speculation: prediction enqueue, fetch
  issuance, prefetching, redirect recovery, and predictor training all flow through it.

## Checkpoint Questions

1. **Basic**: Why can the BPU produce predictions faster than the IFU can consume them? Give two
   common causes of IFU stalls.
2. **Basic**: What is the runahead distance, and why must it be bounded?
3. **Basic**: Name the four main pointers in a multi-pointer FTQ and what each tracks.
4. **Intermediate**: Why does the FTQ store predictor recovery metadata (e.g., GHR snapshot) rather
   than having the BPU recompute it on a redirect?
5. **Intermediate**: Explain the difference between resolve-time training and commit-time training.
   Why might a RAS update prefer commit-time training?
6. **Intermediate**: How does fetch-directed prefetching use the FTQ's runahead to improve ICache
   hit rates?
7. **Advanced**: If the BPU achieves 97% accuracy and the FTQ allows 8 entries of runahead, what
   fraction of prefetches are expected to be useful? What happens to the useless ones?
8. **Advanced**: Consider a design where the FTQ stores only PCs (no metadata), and recovery
   metadata is stored in the BPU itself using a separate checkpoint buffer. What are the trade-offs
   compared to storing metadata in the FTQ?

## Further Reading

1. Reinman, G., Austin, T., and Calder, B. "A Scalable Front-End Architecture for Fast Instruction
   Delivery." ISCA 1999. *The paper that introduced the Fetch Target Queue concept.*
2. Reinman, G., Calder, B., and Austin, T. "Fetch Directed Instruction Prefetching." MICRO 1999.
   *Extends the FTQ concept to drive instruction prefetching.*
3. Seznec, A. "A New Case for the TAGE Branch Predictor." MICRO 2011. *Background on the predictor
   that drives FTQ training requirements.*
4. Smith, J. E. and Sohi, G. S. "The Microarchitecture of Superscalar Processors." Proceedings of
   the IEEE, 1995. *Broader context for decoupled frontend architectures.*
5. Sprangle, E. and Patt, Y. "Facilitating Superscalar Processing via a Combined Static/Dynamic
   Branch Prediction." MICRO 1997. *Early work on decoupled prediction and fetch.*
