# Chapter 26. Directory-Based Coherence and Networks-on-Chip

Part IV described how a single core's load and store pipelines interact with the L1 data cache. That
story was self-contained: one core, one cache, one consistent view of memory. But XiangShan is a
multi-core processor. Each core has its own private L1 and L2 caches, and those caches may hold
copies of the same cache line simultaneously. When one core writes to a shared line, every other
core's copy becomes stale. Without a mechanism to keep those copies consistent, software's most
basic assumption — that a store is visible to subsequent loads — breaks silently across cores.

This chapter teaches the two mechanisms that solve this problem: **directory-based cache coherence**
and **networks-on-chip (NoCs)**. The coherence directory tracks which caches hold which lines and
in what state, so that writes can be propagated precisely to the caches that need to know. The
network-on-chip provides the physical fabric that carries coherence messages between cores, caches,
and memory controllers.

We present these ideas using the terminology of **AMBA CHI** (Coherent Hub Interface), the protocol
that XiangShan's `CHIConfig` implements. CHI defines three node types — Request Node (RN-F), Home
Node (HN-F), and Slave Node (SN-F) — and four channel types — REQ, SNP, RSP, and DAT. Rather than
teaching generic coherence vocabulary and then translating it into CHI in Chapter 27, we introduce
the CHI terms here so that the reader builds a single, consistent mental model from the start.

**Prerequisites:** Part IV (memory subsystem), especially Chapter 23 (L1 data cache).

---

### ASCII Mental Model (Read This First)

```text
The Coherence Problem:                    The Directory Solution:

  Core 0         Core 1                     Core 0 (RN-F)    Core 1 (RN-F)
  ┌─────┐       ┌─────┐                     ┌─────┐          ┌─────┐
  │ L1  │       │ L1  │                     │ L1  │          │ L1  │
  │X=42 │       │X=42 │                     │X=42 │          │X=42 │
  └──┬──┘       └──┬──┘                     └──┬──┘          └──┬──┘
     │             │                            │                │
  ┌──┴──┐       ┌──┴──┐                     ┌──┴──┐          ┌──┴──┐
  │ L2  │       │ L2  │                     │ L2  │          │ L2  │
  │X=42 │       │X=42 │                     │X=42 │          │X=42 │
  └──┬──┘       └──┬──┘                     └──┬──┘          └──┴──┘
     │             │                            │     SNP        ↑
     └──────┬──────┘                            ├────(SnpUnique)─┘
            │                                   │
     ┌──────┴──────┐                     ┌──────┴──────┐
     │   Memory    │                     │  HN-F       │
     │  (no idea   │                     │  Directory: │
     │   who has   │                     │  X: SC by   │
     │   copies)   │                     │  {RN0, RN1} │
     └─────────────┘                     └──────┬──────┘
                                                │
   Core 0 writes X=99.                   ┌──────┴──────┐
   Core 1 still sees X=42.              │  SN-F       │
   WRONG.                                │  (Memory)   │
                                         └─────────────┘

                                         Core 0 writes X=99.
                                         HN-F sends SnpUnique to Core 1.
                                         Core 1 invalidates its copy.
                                         CORRECT.
```

**A directory (the HN-F in CHI) tracks every cached copy of every line. When a core writes, the
directory sends targeted invalidations only to caches that hold copies — no broadcasts, no
guessing.**

---

## 26.1 The Coherence Problem at Scale

### 26.1.1 Why caches create correctness problems in multi-core

Consider two cores, each with a private L2 cache, sharing a variable `X`. Both cores read `X` from
memory, so both L2 caches hold a copy with value 42. Now Core 0 executes `store X, 99`. Its own L2
updates to 99, but Core 1's L2 still holds 42. If Core 1 reads `X`, it sees the stale value — a
coherence violation.

This is not a performance problem; it is a **correctness** problem. Lock-free algorithms, spinlocks,
and even the most basic producer-consumer patterns depend on stores being visible to other cores.
Without coherence, multi-threaded software does not work.

A cache coherence protocol must enforce two invariants:

| Invariant | Meaning |
|---|---|
| **Write propagation** | A write by any core must eventually become visible to all cores. |
| **Write serialization** | All cores must observe writes to the same address in the same order. |

Write propagation is about liveness: no stale values forever. Write serialization is about
consistency: if Core 0 writes `X=1` then `X=2`, every other core must see `1` before `2`, never the
reverse. Together, these two properties are what it means for a memory system to be *coherent*.

### 26.1.2 Snooping: the first solution and its limits

The earliest multi-core systems solved coherence with **bus-based snooping**. Every cache miss or
write is broadcast on a shared bus. All other caches "snoop" the bus, watching for addresses they
hold. If a cache sees a write to an address it has cached, it invalidates or updates its copy.

Snooping works because the shared bus provides a natural serialization point: all requests appear
on the bus in a single total order, so write serialization comes for free. At 2–4 cores, this is
elegant and simple.

But the bus is a shared medium with fixed bandwidth. Every miss generates a broadcast that every
cache must examine. The traffic scales as O(N) messages per miss, where N is the number of caches.
The bus bandwidth required to sustain this grows quadratically with core count times miss rate.

```text
Bus-based snooping at 4 cores:          Bus-based snooping at 16 cores:

  C0   C1   C2   C3                       C0  C1  C2  C3  C4  C5  C6  C7
   │    │    │    │                         │   │   │   │   │   │   │   │
   └────┴────┴────┘                         └───┴───┴───┴───┴───┴───┴───┘
          │                                              │
   ┌──────┴──────┐                            ┌──────────┴──────────┐
   │  Shared Bus │  ← 4 snoops per miss      │     Shared Bus      │
   │  (OK: bus   │                            │  16 snoops/miss     │
   │   handles   │                            │  4× address traffic │
   │   the load) │                            │  snoop filters full │
   └──────┬──────┘                            │  BUS SATURATED      │
          │                                   └──────────┬──────────┘
      ┌───┴───┐                                          │
      │Memory │                        C8  C9  C10 C11 C12 C13 C14 C15
      └───────┘                         │   │   │   │   │   │   │   │
                                        └───┴───┴───┴───┴───┴───┴───┘
                                                     │
                                          (bus can't fit them all)
```

At 8–16 cores, snooping hits a bandwidth wall. Each miss forces the bus to carry N snoop requests
and N snoop responses, but most of those snoops return "I don't have that line" — wasted bandwidth
and wasted energy. Measurements on real workloads show that over 95% of snoops at 16 cores are
negative (the snooped cache does not hold the line). The bus becomes the bottleneck long before the
caches or the cores saturate.

### 26.1.3 The directory idea: track who has what

The fundamental insight behind directory-based coherence is simple: if you record which caches
hold each line and in what state, you can send messages **only to the caches that care**.

Instead of broadcasting "who has line X?", the requester sends a single message to a **home node**
that maintains a directory entry for X. The home node looks up X's entry, sees which caches hold
copies, and sends targeted snoops only to those caches. The response goes directly back to the
requester.

In CHI terminology:

| Concept | CHI term | Role |
|---|---|---|
| Requester (the cache that needs data) | **Request Node (RN-F)** | Initiates coherent transactions |
| Home (the directory that tracks state) | **Home Node (HN-F)** | Point-of-Coherence; resolves state |
| Memory endpoint | **Slave Node (SN-F)** | Serves data when HN-F does not have it |

The bandwidth per miss is now O(1): one request to the HN-F, a small number of snoops to actual
sharers (often zero or one), and a data response back. The total system bandwidth grows linearly
with core count, not quadratically. This is why every modern multi-core processor with more than
four cores uses some form of directory-based coherence.

---

## 26.2 Directory-Based Coherence Mechanisms

### 26.2.1 Directory organization

The directory is a table indexed by cache-line address. Each entry records two things: the
**coherence state** of the line and the **identity of caches that hold copies**. How the second
piece of information is stored defines the directory organization.

**Full bit-vector directory.** One presence bit per RN-F per line. If there are N Request Nodes and
the last-level cache has M lines, the directory needs N × M bits. This is perfectly precise — the
HN-F knows exactly which RN-F nodes hold copies — but the storage cost scales linearly with core
count. For 16 cores, each directory entry adds 16 presence bits plus state bits. For a 16 MB LLC
with 64-byte lines (262,144 entries), that is 16 × 262,144 = 4,194,304 bits ≈ 512 KB just for
presence tracking.

**Coarse bit-vector.** Group multiple RN-F nodes into clusters and track presence per cluster. An
invalidation to a cluster snoops all nodes in it, even if only one holds the line. This trades
precision for area: fewer bits per entry, but more unnecessary snoops.

**Limited-pointer directory.** Track at most K sharers explicitly (e.g., K=2 or K=4). If more than K
caches share a line, the directory falls back to broadcast. This works well when most lines have
few sharers — which is the common case. Studies show that over 90% of shared lines have two or
fewer sharers. The rare lines with many sharers (e.g., lock variables) trigger broadcast, but
their frequency is low enough that overall bandwidth remains manageable.

**Snoop filter.** An inverse directory that tracks only lines that are currently cached by some
RN-F, rather than tracking the state of every line in memory. This is the approach used by
XiangShan's OpenLLC: the directory storage is proportional to the aggregate private-cache capacity,
not to the memory size. Lines not present in any private cache have no directory entry — they are
implicitly in Invalid state.

| Organization | Precision | Storage cost | Broadcast fallback? |
|---|---|---|---|
| Full bit-vector | Exact | O(N) bits per LLC line | No |
| Coarse bit-vector | Per-cluster | O(N/G) bits per LLC line | Within clusters |
| Limited pointer (K) | Exact up to K sharers | O(K × log N) bits per line | Yes, when sharers > K |
| Snoop filter | Exact for cached lines | O(aggregate L2 capacity) | On snoop filter eviction |

### 26.2.2 Coherence states: the CHI model

A coherence protocol assigns a state to each cache-line copy. The state encodes two properties:
**validity** (does this copy contain usable data?) and **ownership** (is this cache responsible for
writing the line back to memory?).

CHI defines five stable cache-line states. These map onto the MOESI model familiar from textbooks,
but with finer distinctions that give the protocol more flexibility.

| CHI state | Full name | Valid? | Unique? | Dirty? | MOESI equivalent |
|---|---|---|---|---|---|
| **I** | Invalid | No | — | — | Invalid |
| **SC** | Shared Clean | Yes | No | No | Shared |
| **UC** | Unique Clean | Yes | Yes | No | Exclusive |
| **UD** | Unique Dirty | Yes | Yes | Yes | Modified |
| **SD** | Shared Dirty | Yes | No | Yes | Owned |

The key distinctions:

- **Unique** means this is the only cached copy. The holder may write without notifying anyone.
- **Shared** means other caches may also hold copies. Writing requires an upgrade transaction.
- **Dirty** means the cache holds the most recent value, which differs from memory. The holder is
  responsible for writing back before the line can be evicted.
- **Clean** means the copy matches memory (or the holder is not responsible for writeback).

The **SD** (Shared Dirty) state is worth special attention. It means: "I have a valid copy, other
caches may also have valid copies, but I am the one responsible for writeback." This state exists
because CHI allows dirty data to be transferred to a new sharer while the original owner retains
responsibility. SD avoids a costly writeback-then-reshare sequence.

The HN-F's directory does not track the same states as the individual caches. The directory tracks
**aggregate** state: is the line uncached, shared by multiple RN-F nodes, or exclusively held by
one? The directory's view might be "line X is in Shared state, held by RN-F 0 and RN-F 2" — but
it does not know whether RN-F 0 has SC or SD. The directory knows enough to decide which snoops
to send; the individual cache's response reveals its precise state.

### 26.2.3 Point-of-Coherence and Point-of-Serialization

CHI defines two architectural concepts that anchor where correctness is enforced:

**Point-of-Coherence (PoC)** is the location in the memory hierarchy where a cache line's most
up-to-date value is guaranteed to be visible to all observers. Below the PoC (closer to memory),
there is only one version of the truth. Above the PoC (in private caches), there may be stale
copies that have not yet been invalidated.

In XiangShan, the **HN-F (OpenLLC)** is the Point-of-Coherence. When the HN-F processes a
coherent request, it ensures that the response reflects the globally latest value — either from
its own data store, from a snooped cache, or from memory via the SN-F.

**Point-of-Serialization (PoS)** is the location where all requests to the same address are
ordered into a single sequence. Two concurrent requests to the same line — say, a ReadUnique from
RN-F 0 and a ReadShared from RN-F 1 — must be processed one at a time. The PoS determines which
goes first.

In CHI, the HN-F is typically both the PoC and the PoS. This is the case in XiangShan: the
OpenLLC serializes all requests to a given address through a single MSHR (miss-status holding
register) per address, guaranteeing that concurrent requests to the same line are processed in
a well-defined order.

These concepts matter for understanding why certain message orderings are safe and others are not.
When we trace coherence transactions in Section 26.3, the PoC and PoS are the invariants that
explain why the protocol works.

### 26.2.4 Inclusion policies

The relationship between the directory (HN-F) and the private caches (RN-F) is constrained by
the **inclusion policy**: which level of the hierarchy is required to hold a superset of the data
in the levels above it.

**Inclusive.** The LLC always holds a copy of every line cached in any private cache. If the LLC
must evict a line, it sends a **back-invalidation** to all private caches that hold it, forcing
them to evict too. This simplifies snoop filtering — if a line is not in the LLC, it is not in
any private cache — but wastes LLC capacity by storing duplicate copies of hot lines.

**Exclusive.** A line lives in exactly one level of the hierarchy. When a line is fetched into a
private cache, it is removed from the LLC. On eviction from the private cache, it returns to the
LLC. This maximizes effective capacity (the aggregate of LLC + private caches) but complicates
coherence because the LLC cannot serve as a data source for snoops.

**Non-inclusive, non-exclusive (NINE).** The directory tracks which private caches hold each line,
but the LLC may or may not hold a data copy. There is no invariant in either direction.
Back-invalidation is needed only when the directory entry (not the data) must be evicted. This is
the approach used by XiangShan's OpenLLC: the snoop filter tracks RN-F presence, and the LLC data
array acts as a victim cache for data evicted from private caches.

| Policy | LLC capacity efficiency | Back-invalidation traffic | Directory complexity |
|---|---|---|---|
| Inclusive | Low (duplicates private-cache data) | On every LLC eviction | Simple (LLC = snoop filter) |
| Exclusive | High (no duplicates) | None (lines swap between levels) | Higher (must track swaps) |
| NINE | Medium (selective duplication) | Only on directory eviction | Medium (separate snoop filter) |

The choice of inclusion policy interacts with working-set size. For workloads whose hot data fits
in the private caches, inclusive and NINE perform similarly — the LLC stores few extra copies. For
workloads with large footprints that exceed private cache capacity, NINE and exclusive designs
provide more effective total capacity because the LLC is not wasting space on duplicates.

---

## 26.3 Coherence Transactions Step by Step

To make the protocol concrete, we trace four fundamental transactions through a system with two
RN-F nodes (Core 0 and Core 1, each with a private L2 cache), one HN-F (the directory and LLC),
and one SN-F (memory). We use CHI transaction names and message types throughout.

### 26.3.1 Read miss to a clean line (no snoop needed)

**Scenario:** Core 0 loads address X. X is not in Core 0's L2 (state I). The HN-F directory says
X is not cached by any RN-F (also state I).

```text
   RN-F 0              HN-F (directory)           SN-F (memory)
     │                       │                          │
     │──── ReadShared(X) ───>│                          │
     │     [REQ channel]     │                          │
     │                       │── ReadNoSnp(X) ─────────>│
     │                       │   [REQ channel]          │
     │                       │                          │
     │                       │<──── CompData(X, data) ──│
     │                       │      [DAT channel]       │
     │                       │                          │
     │<── CompData(X, UC) ───│                          │
     │    [DAT channel]      │                          │
     │                       │                          │
     │──── CompAck ─────────>│                          │
     │    [RSP channel]      │                          │
     │                       │                          │
```

**Step 1.** RN-F 0 sends a `ReadShared` request on the REQ channel. This says: "I need a copy of
line X; shared access is sufficient."

**Step 2.** The HN-F looks up X in its directory. No RN-F holds a copy, so no snoops are needed.
The HN-F checks its own data store. If it has the data (a previous writeback left it there), it
responds directly. If not, it sends `ReadNoSnp` to the SN-F to fetch from memory.

**Step 3.** The SN-F returns the data via `CompData` on the DAT channel.

**Step 4.** The HN-F forwards the data to RN-F 0 as `CompData` with state UC (Unique Clean).
The state is UC, not SC, because RN-F 0 is the only requester — giving it unique ownership avoids
a future upgrade transaction if Core 0 decides to write.

**Step 5.** RN-F 0 sends `CompAck` on the RSP channel. This tells the HN-F that the transaction
is complete and the HN-F can release the tracking entry (MSHR) for address X.

**Directory state after:** X → {RN-F 0, state UC}.

**Message count:** 4 messages total (ReadShared, ReadNoSnp, two CompData, CompAck) — 5 if counting
the SN-F response separately. Compare with snooping, which would broadcast the miss to all N
caches regardless.

### 26.3.2 Read miss to an exclusively-owned line (snoop required)

**Scenario:** Core 0 holds X in state UD (Unique Dirty — it has written to X). Core 1 now wants
to read X.

```text
   RN-F 0              HN-F (directory)           RN-F 1
     │                       │                       │
     │                       │<── ReadShared(X) ─────│
     │                       │    [REQ channel]      │
     │                       │                       │
     │<── SnpSharedFwd(X) ───│                       │
     │    [SNP channel]      │                       │
     │                       │                       │
     │──────────── CompData(X, data, SC) ───────────>│
     │             [DAT channel, direct to RN-F 1]   │
     │                       │                       │
     │── SnpResp(SC) ───────>│                       │
     │   [RSP channel]       │                       │
     │                       │                       │
     │                       │──── Comp(SC) ────────>│
     │                       │    [RSP channel]      │
     │                       │                       │
     │                       │<──── CompAck ─────────│
     │                       │     [RSP channel]     │
     │                       │                       │
```

**Step 1.** RN-F 1 sends `ReadShared(X)` to the HN-F.

**Step 2.** The HN-F looks up X: state UD, held by RN-F 0. Since RN-F 0 has the only valid copy
(and it is dirty), the HN-F must snoop it. It sends `SnpSharedFwd(X)` on the SNP channel. The
"Fwd" suffix is a CHI optimization: it tells RN-F 0 to forward the data directly to RN-F 1
rather than sending it back through the HN-F. This saves one hop and reduces HN-F bandwidth
consumption.

**Step 3.** RN-F 0 receives the snoop. It downgrades from UD to SD (Shared Dirty — it still
holds a copy and remains responsible for eventual writeback). It sends the data directly to
RN-F 1 via `CompData` on the DAT channel, with the granted state SC (Shared Clean).

**Step 4.** RN-F 0 also sends `SnpResp(SC)` to the HN-F, informing it of the new local state.

**Step 5.** The HN-F sends `Comp(SC)` to RN-F 1, confirming the transaction. RN-F 1 replies
with `CompAck`.

**Directory state after:** X → {RN-F 0 (SD), RN-F 1 (SC)}.

This is the **three-party transaction** pattern that dominates multi-core coherence: requester
→ home → snooped owner → (data to requester, response to home) → completion. The HN-F
orchestrates the exchange but avoids being in the data path when forwarding is possible.

### 26.3.3 Write miss: upgrade from Shared to Unique

**Scenario:** X is in state SC at RN-F 0 and SC at RN-F 1 (both shared, clean copies). Core 0
wants to write to X and needs exclusive ownership.

```text
   RN-F 0              HN-F (directory)           RN-F 1
     │                       │                       │
     │── MakeUnique(X) ─────>│                       │
     │   [REQ channel]       │                       │
     │                       │                       │
     │                       │── SnpUnique(X) ──────>│
     │                       │   [SNP channel]       │
     │                       │                       │
     │                       │<── SnpResp(I) ────────│
     │                       │    [RSP channel]      │
     │                       │                       │
     │<──── Comp(UC) ────────│                       │
     │      [RSP channel]    │                       │
     │                       │                       │
     │──── CompAck ─────────>│                       │
     │    [RSP channel]      │                       │
     │                       │                       │
```

**Step 1.** RN-F 0 sends `MakeUnique(X)`. This is a *dataless* transaction: RN-F 0 already has
the data (in SC state), so it only needs permission to write, not a data transfer.

**Step 2.** The HN-F sees that RN-F 1 also holds X in SC. It sends `SnpUnique(X)` to RN-F 1,
demanding invalidation.

**Step 3.** RN-F 1 invalidates its copy and responds with `SnpResp(I)`.

**Step 4.** The HN-F grants ownership to RN-F 0 by sending `Comp(UC)`. No data payload needed.

**Step 5.** RN-F 0 sends `CompAck`, and transitions from SC to UC (then to UD when the store
actually writes). The HN-F updates its directory: X → {RN-F 0, state UC}.

This transaction is the **expensive case** for directories: the fan-out of invalidation snoops
scales with the number of sharers. If eight RN-F nodes share a line, the HN-F must send eight
`SnpUnique` messages and wait for eight `SnpResp` completions before granting ownership. For
heavily shared lines (locks, barriers), this becomes a serialization bottleneck. The
limited-pointer directory handles this by falling back to broadcast when the sharer count
exceeds K; the snoop filter handles it by having storage proportional to the aggregate L2 size,
naturally limiting the maximum sharer count to the number of RN-F nodes.

### 26.3.4 Eviction and writeback

**Scenario:** RN-F 0 holds X in state UD (dirty) and must evict it to make room for a new line.

```text
   RN-F 0              HN-F (directory)           SN-F (memory)
     │                       │                          │
     │── WriteBackFull(X) ──>│                          │
     │   [REQ channel]       │                          │
     │                       │                          │
     │<── CompDBIDResp ──────│                          │
     │    [RSP channel]      │                          │
     │                       │                          │
     │── CBWrData(X, data) ─>│                          │
     │   [DAT channel]       │                          │
     │                       │                          │
     │                       │── WriteNoSnp(X, data) ──>│
     │                       │   (optional, to memory)  │
     │                       │                          │
```

**Step 1.** RN-F 0 sends `WriteBackFull(X)` on the REQ channel. This notifies the HN-F that a
dirty line is being evicted.

**Step 2.** The HN-F responds with `CompDBIDResp`, which serves double duty: it acknowledges the
writeback (Comp) and provides a Data Buffer ID (DBID) that the RN-F must include in the data
transfer. The DBID lets the HN-F match the incoming data to the correct request when multiple
writebacks are in flight.

**Step 3.** RN-F 0 sends the dirty data via `CBWrData` (Copyback Write Data) on the DAT channel.

**Step 4.** The HN-F updates its directory (X → I, or retains the data in the LLC). If the LLC
is full and cannot absorb the writeback, the HN-F forwards the data to the SN-F via
`WriteNoSnp`.

For **clean evictions**, RN-F 0 sends `Evict(X)` instead of `WriteBackFull`. Since the data
matches memory, no data transfer is needed — just a notification so the HN-F can update its
directory. In an inclusive LLC, the HN-F already has the data. In a NINE design, the HN-F may
or may not need the data, but the directory entry must be updated regardless.

**Silent eviction** — dropping a clean line without notifying the HN-F — is **not permitted** in
directory-based protocols (unlike bus-based snooping, where the bus naturally observes all
traffic). If a cache silently drops a line, the directory still thinks the cache holds it and
will send snoops to a cache that can no longer respond. CHI enforces this by requiring an
`Evict` notification for every clean line eviction from an RN-F.

---

## 26.4 Networks-on-Chip: Moving Coherence Traffic

### 26.4.1 Why a bus is not enough

Sections 26.1 through 26.3 described coherence as a message-passing protocol: RN-F sends a
request on the REQ channel, HN-F sends a snoop on the SNP channel, data flows on the DAT
channel. But what physical structure carries these messages between nodes?

At 2–4 cores, a shared bus or simple crossbar suffices. All nodes connect to a single shared
medium, and the arbiter grants access to one sender at a time. But shared buses have two
fundamental limits:

1. **Bandwidth.** A bus can carry one transaction at a time. As core count increases, contention
   grows and throughput saturates.
2. **Wire length.** A bus that spans the entire chip becomes a long wire with high capacitance.
   Signal propagation delay grows, and the achievable clock frequency drops.

A **network-on-chip (NoC)** replaces the shared bus with a packet-switched fabric. Each node
connects to a local router, and routers are connected by point-to-point links in some topology.
Messages are broken into **flits** (flow-control units) and routed hop by hop through the
network. Multiple messages can be in flight simultaneously on different links, providing
aggregate bandwidth that scales with the number of links rather than being limited by a single
shared medium.

### 26.4.2 Topology vocabulary

The choice of NoC topology is a three-way trade-off between area, latency, and bandwidth. Four
topologies dominate modern designs:

**Crossbar.** Every node has a direct connection to every other node. Latency is minimal (one hop),
and bandwidth is maximal (N simultaneous transfers). But the area cost is O(N²) — each additional
node requires a new wire to every existing node. Crossbars are practical up to about 8–16 ports.
XiangShan's current OpenLLC uses a crossbar internally to connect RN-F ports to LLC slices.

**Ring.** Nodes are arranged in a unidirectional or bidirectional ring. Each message hops from
router to router around the ring. Area is O(N), and the worst-case latency is N/2 hops
(bidirectional) or N-1 hops (unidirectional). Intel used ring topologies from Sandy Bridge
through Skylake for up to 8–12 cores.

**2D Mesh.** Nodes are arranged in a √N × √N grid, each connected to its four neighbors (north,
south, east, west). Area is O(N), worst-case latency is 2(√N − 1) hops, and bisection bandwidth
scales as O(√N). This is the topology of choice for many-core designs: ARM's CMN-600/CMN-700
mesh interconnect and Intel's server-class Xeon mesh both use 2D meshes.

**Hierarchical.** Clusters of 2–4 nodes use a crossbar within the cluster, and clusters are
connected by a ring or mesh. This combines the low latency of a crossbar (for intra-cluster
traffic) with the scalability of a mesh (for inter-cluster traffic). ARM's DynamIQ Shared Unit
(DSU) uses this pattern: a small snooping crossbar within a 4-core cluster, and CHI between
clusters.

| Topology | Area | Worst-case hops (N nodes) | Bisection BW | Sweet spot |
|---|---|---|---|---|
| Crossbar | O(N²) | 1 | O(N) | ≤8 nodes |
| Ring | O(N) | N/2 (bidir) | O(1) | 4–12 nodes |
| 2D Mesh | O(N) | 2(√N − 1) | O(√N) | 16–256 nodes |
| Hierarchical | O(N) | Cluster-local: 1; cross-cluster: varies | Varies | Mixed locality |

### 26.4.3 Router microarchitecture (conceptual)

Each router in a NoC is a small switching element with the following components:

```text
              ┌───────────────────────────────┐
  North In ──>│ ┌─────────┐   ┌───────────┐  │──> North Out
              │ │  Input   │   │           │  │
  South In ──>│ │  Buffers │──>│  Crossbar │  │──> South Out
              │ │  (per VC)│   │  Switch   │  │
  East In  ──>│ │         │   │           │  │──> East Out
              │ └─────────┘   └───────────┘  │
  West In  ──>│        ↑ credit return       │──> West Out
              │                               │
  Local In ──>│   ┌──────────────────────┐   │──> Local Out
   (node)     │   │  Allocator + Route   │   │    (node)
              │   │  Computation         │   │
              │   └──────────────────────┘   │
              └───────────────────────────────┘
```

**Input buffers** store incoming flits until they can be forwarded. Each input port has multiple
**virtual channels (VCs)** — logically separate buffer pools that share the same physical link.
Virtual channels serve two critical purposes: they prevent **head-of-line blocking** (a stalled
flit in one VC does not block flits in other VCs) and they prevent **protocol-level deadlocks**
(more on this in Section 26.4.5).

**Credit-based flow control** prevents buffer overflow. Each output port tracks how many buffer
slots the downstream router has available (its *credit count*). A flit can only be sent if the
sender holds at least one credit for the destination port. When the downstream router frees a
buffer slot, it sends a credit back. CHI uses this same principle for its **L-Credit** mechanism
at the link layer: each channel (REQ, SNP, RSP, DAT) has its own credit pool, and a sender
cannot transmit a flit without holding a credit.

**Crossbar switch** connects any input port to any output port in a given cycle. The allocator
resolves contention when multiple inputs want the same output.

### 26.4.4 Routing

Routing determines the path a flit takes from source to destination. The most common strategies:

**Deterministic (XY) routing.** In a 2D mesh, first route in the X (east-west) direction, then in
the Y (north-south) direction. The path is fully determined by source and destination coordinates.
Simple, deadlock-free (because turns are restricted), and easy to verify. This is the default for
most mesh-based NoCs.

**Adaptive routing.** The router examines congestion on neighboring links and chooses among multiple
legal paths. Better load balancing under non-uniform traffic, but harder to prove deadlock-free
and harder to verify.

**Source routing.** The sender encodes the entire path in the flit header. Routers need no routing
tables — they just follow the path. This minimizes router complexity but limits adaptivity.

**Table-based routing.** Each router has a small table mapping destination IDs to output ports.
Flexible, supports irregular topologies, but adds area and latency for the table lookup.

CHI itself is topology-agnostic at the protocol layer — it specifies message types and ordering
rules, not routing. The network layer is an implementation choice. XiangShan's current design
uses a crossbar (effectively one-hop routing), but the `XSNoCTop` configuration path is designed
to support a real NoC topology for scaled-out configurations.

### 26.4.5 Mapping coherence to NoC channels

Coherence traffic is not homogeneous. A `ReadShared` request, a `SnpUnique` snoop, a data
response, and a `CompAck` acknowledgment are fundamentally different message types with different
flow-control requirements. If they all share a single NoC channel, a subtle and dangerous problem
arises: **protocol-level deadlock**.

Consider this scenario: RN-F 0 sends a `ReadUnique` that fills the HN-F's request buffer. The
HN-F needs to send `SnpUnique` to RN-F 1, but the snoop channel is full because RN-F 1's input
buffer is occupied by a data response that RN-F 1 cannot consume because it is waiting for an
acknowledgment that is stuck behind another snoop. No message can move. Deadlock.

The solution is to assign coherence message types to **separate virtual networks** on the NoC,
each with its own buffer resources. CHI defines four channel types that must not block each other:

| CHI channel | Direction | Content | Deadlock role |
|---|---|---|---|
| **REQ** | RN-F → HN-F | Coherent requests (ReadShared, MakeUnique, WriteBackFull, ...) | Can generate snoops and responses |
| **SNP** | HN-F → RN-F | Snoop commands (SnpShared, SnpUnique, SnpSharedFwd, ...) | Generated by requests; generates snoop responses |
| **RSP** | Bidirectional | Completions and acknowledgments (Comp, CompAck, SnpResp, ...) | Consumed without generating further messages |
| **DAT** | Bidirectional | Data payloads with coherence metadata (CompData, CBWrData, ...) | Consumed without generating further messages |

The critical property is that **responses (RSP) and data (DAT) are always sinkable**: receiving a
response or data transfer never requires sending another message on the same channel. This breaks
the circular dependency chain. A request may generate a snoop, and a snoop may generate a response
and data, but a response never generates anything. The dependency graph is acyclic:
REQ → SNP → {RSP, DAT} — with no back-edges.

In a NoC implementation, each channel type maps to a separate virtual network (or at minimum, a
separate virtual channel class). This guarantees that a stalled request cannot block snoop delivery,
and a stalled snoop cannot block response consumption. The cost is additional buffer area (four
sets of buffers per router instead of one), but the correctness guarantee is essential. No
practical directory protocol can function without this separation.

---

## 26.5 Worked Example: 4-Core Directory Coherence on a Ring

### 26.5.1 Setup

To make the protocol tangible, we trace two consecutive transactions through a specific system.

```text
                        ┌─────────┐
                   ┌───>│  RN-F 0 │<───┐
                   │    │ (Core 0)│    │
                   │    └─────────┘    │
                   │                   │
              ┌────┴────┐         ┌────┴────┐
              │  RN-F 3 │         │  RN-F 1 │
              │(Core 3) │         │(Core 1) │
              └────┬────┘         └────┬────┘
                   │                   │
                   │    ┌─────────┐    │
                   └───>│  HN-F   │<───┘
                        │(Home +  │
                        │  LLC)   │
                        └────┬────┘
                             │
                        ┌────┴────┐
                        │  SN-F   │
                        │(Memory) │
                        └─────────┘

         Bidirectional ring. Each link: 1 hop.
         RN-F 0 to HN-F: 2 hops (via RN-F 3 or RN-F 1).
         RN-F 0 to RN-F 2: does not exist in this 4-core example;
         the ring has 5 nodes total (4 RN-F + 1 HN-F).
```

Assumptions:
- 4 cores (RN-F 0 through RN-F 3) and 1 HN-F on a bidirectional ring.
- Each link traversal takes 1 cycle. Router pipeline adds 1 cycle per hop.
- Cache line X starts in state I everywhere (no cached copies).

### 26.5.2 Trace: Core 0 reads X, then Core 2 writes X

**Transaction 1: Core 0 reads X (ReadShared)**

| Cycle | Event | Channel | Hops |
|---|---|---|---|
| 0 | RN-F 0 sends ReadShared(X) toward HN-F | REQ | — |
| 2 | ReadShared(X) arrives at HN-F (2 hops via RN-F 1) | REQ | 2 |
| 3 | HN-F looks up directory: X is I. No snoops needed. | — | — |
| 3 | HN-F has data in LLC (or fetches from SN-F; assume LLC hit). | — | — |
| 4 | HN-F sends CompData(X, UC) toward RN-F 0. | DAT | — |
| 6 | CompData arrives at RN-F 0. | DAT | 2 |
| 7 | RN-F 0 sends CompAck toward HN-F. | RSP | — |
| 9 | CompAck arrives at HN-F. HN-F deallocates MSHR. | RSP | 2 |

**Total latency:** 6 cycles from request to data arrival. **Total messages:** 3.

**Directory state:** X → {RN-F 0, UC}.

**Transaction 2: Core 2 writes X (ReadUnique)**

Core 2 needs exclusive ownership for a store. X is currently UC at RN-F 0.

| Cycle | Event | Channel | Hops |
|---|---|---|---|
| 10 | RN-F 2 sends ReadUnique(X) toward HN-F. | REQ | — |
| 12 | ReadUnique(X) arrives at HN-F. | REQ | 2 |
| 13 | HN-F looks up directory: X held by RN-F 0 in UC state. | — | — |
| 13 | HN-F sends SnpUniqueFwd(X, fwd=RN-F 2) to RN-F 0. | SNP | — |
| 15 | SnpUniqueFwd arrives at RN-F 0. | SNP | 2 |
| 16 | RN-F 0 invalidates X (UC → I), forwards data to RN-F 2. | DAT | — |
| 16 | RN-F 0 sends SnpResp(I) to HN-F. | RSP | — |
| 18 | CompData(X, UD) arrives at RN-F 2 (from RN-F 0, 2 hops). | DAT | 2 |
| 18 | SnpResp(I) arrives at HN-F. | RSP | 2 |
| 18 | HN-F sends Comp(UD) to RN-F 2. | RSP | — |
| 20 | Comp arrives at RN-F 2. | RSP | 2 |
| 20 | RN-F 2 sends CompAck to HN-F. | RSP | — |
| 22 | CompAck arrives at HN-F. MSHR deallocated. | RSP | 2 |

**Total latency:** 8 cycles from request to data arrival (cycle 10 to 18). **Total messages:** 6
(ReadUnique, SnpUniqueFwd, CompData, SnpResp, Comp, CompAck).

**Directory state:** X → {RN-F 2, UD}.

### 26.5.3 Comparison: what would snooping cost?

In a 4-core snooping system, Transaction 2 would broadcast the write request to all 4 caches (3
snoops). Only 1 snoop (to RN-F 0) produces useful information; the other 2 are wasted. At 16
cores, the same transaction broadcasts to 15 caches — 14 wasted snoops. The directory approach
sends exactly 1 snoop regardless of core count, because only 1 cache holds the line.

| Metric | Snooping (4 cores) | Snooping (16 cores) | Directory (any N) |
|---|---|---|---|
| Snoops per write miss | N − 1 = 3 | N − 1 = 15 | # of sharers (1 here) |
| Wasted snoops | 2 | 14 | 0 |
| Bus bandwidth per miss | O(N) | O(N) | O(1) |

The directory does pay a latency cost: the request must travel to the HN-F, which looks up the
directory and then sends targeted snoops. In snooping, the broadcast goes directly to all caches
in parallel. For small core counts, snooping may be faster. The crossover point where directory
latency is offset by bandwidth savings is typically around 8 cores, though the exact number
depends on workload sharing patterns and interconnect design.

---

## 26.6 Design Trade-Offs

### 26.6.1 Snooping vs. directory

Snooping and directory-based coherence are not binary alternatives but endpoints on a spectrum.

**Pure snooping** broadcasts every miss. Simple, low latency at small scale, no directory storage.
Breaks at 8+ cores due to bandwidth.

**Snoop filter** is a practical middle ground: a directory that records only currently-cached lines,
used to *filter out* unnecessary snoops. Snoops are still sent on the bus or crossbar, but only to
caches that the filter says hold the line. This is how ARM's DSU works within a 4-core cluster.

**Full directory** tracks all lines and sends only targeted messages. Highest bandwidth efficiency,
but adds latency (indirection through the home node) and storage cost. This is what CHI's HN-F
implements for cross-cluster coherence.

**Hybrid designs** combine both: snooping within small clusters (low latency for intra-cluster
sharing) and directory across clusters (bandwidth efficiency for inter-cluster sharing). This is
the architecture of ARM Cortex-A cores in DynamIQ configurations: the DSU handles coherence
within a 4-core cluster, and the CMN mesh uses CHI directory-based coherence between clusters.

### 26.6.2 Topology trade-offs for XiangShan

XiangShan's current `CHIConfig` uses a crossbar inside OpenLLC to connect RN-F ports to LLC
slices. This is appropriate for the current design point (2 cores, 4 LLC slices), where a
crossbar provides minimal latency and manageable area.

For future scaled configurations, the choice between ring, mesh, and hierarchical topologies
depends on:

| Factor | Crossbar | Ring | 2D Mesh |
|---|---|---|---|
| **Latency** (worst case) | 1 hop | N/2 hops | 2(√N − 1) hops |
| **Area scaling** | O(N²) | O(N) | O(N) |
| **Bisection bandwidth** | O(N) | O(1) | O(√N) |
| **Router complexity** | Central arbiter | Simple 3-port | 5-port with VC |
| **Deadlock freedom** | Trivial | Trivial (unidirectional) | Requires XY routing or VCs |
| **Sweet spot** | ≤8 nodes | 4–12 nodes | 16+ nodes |

The mesh becomes clearly superior when the core count exceeds the crossbar's area budget (roughly
8–16 ports) and the workload has enough spatial locality that most traffic is between neighboring
nodes. Workloads with uniform random traffic (every core equally likely to communicate with every
other core) stress the mesh's bisection bandwidth and may favor a higher-radix topology.

### 26.6.3 Directory precision vs. area

The directory's storage cost is a direct function of its precision. For a system with N RN-F nodes
and an LLC with C lines:

| Organization | Bits per directory entry | Total directory storage |
|---|---|---|
| Full bit-vector | N + state bits | C × (N + S) |
| K-pointer | K × ⌈log₂ N⌉ + state bits | C × (K × ⌈log₂ N⌉ + S) |
| Snoop filter | N + state bits (but only for cached lines) | P × (N + S), where P = # cached lines |

For 16 cores, 64-byte lines, 16 MB LLC (C = 262,144 lines), and 3 state bits:

- **Full bit-vector:** 262,144 × (16 + 3) = 4,980,736 bits ≈ **608 KB** (3.7% of LLC capacity)
- **2-pointer:** 262,144 × (2 × 4 + 3) = 2,883,584 bits ≈ **352 KB** (2.1% of LLC capacity)
- **Snoop filter** (assuming aggregate L2 capacity of 4 MB, 65,536 lines): 65,536 × (16 + 3)
  = 1,245,184 bits ≈ **152 KB** (0.9% of LLC capacity)

The snoop filter wins on area because it only allocates entries for lines that are actually cached
in some private cache. The trade-off is that when the snoop filter itself is full and must evict
an entry, it must send a back-invalidation to the private cache that holds that line — even if the
private cache still needs it. This creates additional coherence traffic, but studies show that
snoop filter evictions are rare when the filter is sized to cover the aggregate L2 capacity.

### 26.6.4 Inclusive vs. non-inclusive LLC

| Design decision | Inclusive | Non-inclusive (NINE) |
|---|---|---|
| **Effective cache capacity** | LLC only (private cache data duplicated) | LLC + private caches |
| **Snoop filter needed?** | No (LLC *is* the snoop filter) | Yes (separate structure) |
| **Back-invalidation** | On every LLC eviction | Only on snoop-filter eviction |
| **Coherence simplicity** | Higher (LLC always has data for snoops) | Lower (must track data location) |
| **Best for** | Small private caches, large LLC | Large private caches, bandwidth-sensitive workloads |

XiangShan's OpenLLC uses a **non-inclusive** design. The snoop filter in the HN-F tracks which
RN-F nodes hold each line, but the LLC data array does not necessarily hold a copy of every
privately-cached line. This is the right trade-off for XiangShan's design point: with 1 MB L2
caches per core, an inclusive 4 MB LLC would waste significant capacity on duplicates. The
non-inclusive design lets the LLC store additional unique lines, effectively adding its capacity
to the private caches rather than duplicating them.

---

## 26.7 Common Misconceptions

**"Snooping is obsolete."** Snooping is alive and well inside small clusters. ARM's DynamIQ
Shared Unit (DSU) uses snooping for up to 12 CPUs within a cluster, and CHI directory-based
coherence between clusters. The key insight is that snooping and directories coexist at different
hierarchy levels, chosen by the bandwidth and latency trade-offs at each level.

**"A directory eliminates all broadcasts."** Practical directories are not perfectly precise.
Limited-pointer directories fall back to broadcast when the sharer count exceeds K. Snoop filters
must evict entries when full, triggering back-invalidations. Even a full bit-vector directory
cannot avoid broadcasting when the directory entry itself says "all N caches share this line."
The directory's benefit is that broadcasts become rare (< 1% of transactions in typical workloads),
not that they are eliminated entirely.

**"More cache levels always help."** Adding a cache level (e.g., an L3 between L2 and memory)
adds latency on every miss that passes through it. If the working set fits in L2, the L3 is
never hit and only adds latency to cold misses. If the working set exceeds the L3, the L3 has a
low hit rate and the latency penalty is paid on nearly every access. The benefit is greatest when
the working set is larger than L2 but smaller than L3 — which depends on the application. Cache
hierarchy design is about matching level sizes to working-set distributions, not about adding
levels unconditionally.

**"Coherence traffic is always the bottleneck."** In many real workloads, most cache misses are
to private (unshared) data — stack, local variables, thread-private heap allocations. Coherence
traffic only matters for shared data, which is often a small fraction of total memory accesses.
The directory handles shared data efficiently, and the NoC carries both shared and private traffic.
The actual bottleneck in many systems is memory bandwidth or memory latency, not coherence overhead.

---

## 26.8 Key Takeaways

1. **Directory-based coherence** replaces broadcast snooping with targeted messages. An HN-F
   (Home Node) maintains a directory tracking which RN-F (Request Node) caches hold each line.
   Per-miss bandwidth scales O(1) instead of O(N).

2. CHI defines **five cache-line states** (I, SC, UC, UD, SD) that encode validity, uniqueness,
   and dirty responsibility. The distinction between Unique/Shared and Clean/Dirty gives the
   protocol flexibility to minimize data transfers.

3. **Point-of-Coherence (PoC)** and **Point-of-Serialization (PoS)** are the locations where
   correctness is enforced. In XiangShan, both reside at the HN-F (OpenLLC), which resolves
   coherence state and orders concurrent requests to the same address.

4. **Networks-on-chip** replace shared buses with packet-switched fabrics. Topology choice
   (crossbar, ring, mesh) trades area against latency and bandwidth. CHI is topology-agnostic
   at the protocol layer.

5. **Four separate channel types** (REQ, SNP, RSP, DAT) prevent protocol-level deadlock by
   ensuring that responses are always sinkable — receiving a response never requires sending
   another message on the same channel class.

---

## 26.9 Checkpoint Questions

**Basic:**

1. Why does bus-based snooping fail to scale beyond ~8 cores? What resource becomes the
   bottleneck?

2. What two invariants must a cache coherence protocol enforce? Give a concrete example of a
   program that produces incorrect results if either invariant is violated.

3. In CHI terminology, what is the difference between an RN-F, an HN-F, and an SN-F? Which
   XiangShan module implements each?

**Intermediate:**

4. Explain the difference between the UC and SC cache states. Why would the HN-F grant UC
   instead of SC to a ReadShared requester when no other caches hold the line?

5. Why do coherence protocols need separate NoC virtual channels (or virtual networks) for
   request, snoop, response, and data traffic? Construct a specific 3-node deadlock scenario
   that arises when all message types share a single channel.

6. In a non-inclusive (NINE) LLC, what happens when the snoop filter must evict an entry for
   line Y that is still cached in an RN-F's L2? Compare with the inclusive case.

**Advanced:**

7. A 16-core chip uses a full bit-vector directory. Each directory entry needs one presence bit
   per core plus 3 state bits. Calculate the directory storage overhead as a percentage of LLC
   capacity for 64-byte lines and a 16 MB LLC. Then recalculate for a snoop filter sized to
   cover 8 MB of aggregate L2 capacity. What is the area reduction?

8. Compare ring and 2D mesh topologies for a 16-node design (4 RN-F + 1 HN-F per ring; 4×4
   mesh). Calculate worst-case hop count and bisection bandwidth for each. Under what workload
   characteristics does the mesh become clearly superior?

9. Design a hybrid coherence scheme where a 4-core cluster uses snooping internally and
   directory-based CHI coherence across clusters. What are the boundary conditions at the cluster
   interface? Specifically: when a cross-cluster snoop arrives at a cluster, how does the cluster
   determine which internal cache holds the line without broadcasting?

---

## 26.10 Further Reading

1. Sorin, Hill, and Wood, *A Primer on Memory Consistency and Cache Coherence* (2nd ed., 2020)
   — the definitive graduate reference on coherence protocols and their correctness properties.

2. Dally and Towles, *Principles and Practices of Interconnection Networks* (2004) — topology,
   routing, flow control, and deadlock avoidance fundamentals for on-chip networks.

3. ARM, *AMBA 5 CHI Architecture Specification* (Issue E.b, 2023) — the authoritative CHI
   protocol reference, defining node types, channels, states, and transaction flows.

4. ARM, *CoreLink CMN-700 Technical Reference Manual* — an industry mesh interconnect for
   CHI-based systems, illustrating how the concepts in this chapter are realized in silicon.

5. Martin, Hill, and Sorin, "Why On-Chip Cache Coherence Is Here to Stay" (CACM 2012) — debunks
   the myth that coherence is too expensive for many-core, with quantitative arguments.

6. Chapter 27 of this book — applies these concepts to the specific CHI subset that XiangShan
   implements, with waveform-level transaction traces.
