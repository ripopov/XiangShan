# Appendix I.3 — TileLink in XiangShan: DCache and L2 Cache Implementation

> **Status:** PLAN ONLY — detailed table of contents and section outlines.
> Actual content to be written in a subsequent pass.

---

## Document Plan

**Goal:** Show how XiangShan Kunminghu concretely implements TileLink coherence in its L1
DCache and CoupledL2 cache. This document bridges the protocol specification (Appendix I.2)
with the actual RTL, tracing coherence transactions through the hardware structures. By the
end, the reader should be able to follow a cache miss from the load pipeline through MSHRs,
TileLink channels, L2 slices, and back, understanding every state transition in the RTL.

**Prerequisites:** Appendix I.1 (coherence fundamentals), Appendix I.2 (TileLink
specification), familiarity with XiangShan's memory subsystem overview (Chapter 19).

**Key source directories:**
- `src/main/scala/xiangshan/cache/` — L1 DCache
- `coupledL2/src/main/scala/coupledL2/` — L2 Cache
- `src/main/scala/xiangshan/mem/` — Load/Store pipelines (TileLink client side)

---

## Table of Contents

### 1. XiangShan Coherence Architecture Overview
- 1.1 Two-Level Coherence Hierarchy
  - L1 DCache (private, per-core) ↔ CoupledL2 (private L2, per-core) ↔ LLC/memory
  - Which TileLink conformance level at each boundary
  - Inner edge (L1↔L2): TL-C, coherent
  - Outer edge (L2↔LLC): TL-C or CHI (configurable)
- 1.2 Agent Roles in XiangShan
  - DCache as TileLink master/client
  - CoupledL2 slices as both slave (to L1) and master (to LLC)
  - Directory/coherence tracking in L2
- 1.3 Bus Topology and Diplomacy Parameters
  - TileLink edge widths: address, data, source/sink ID
  - How Diplomacy negotiation works in XiangShan's `BusTopology`
  - Parameter extraction from `XSCoreParameters` and `L2Param`
  - Key source references to parameter definitions

### 2. L1 DCache: TileLink Client Implementation
- 2.1 DCache Top-Level TileLink Interface
  - `DCacheIO` and the TileLink client port
  - Source ID allocation and tracking
  - Connection to L2 via `TLClientNode`
- 2.2 Miss Handling: MissQueue and MSHRs
  - `MissQueue` structure and MSHR allocation
  - MSHR states and TileLink transaction mapping
  - When an MSHR issues AcquireBlock vs. AcquirePerm
  - Source ID management: allocation, in-flight tracking, release
  - Key source references: `MissQueue.scala`, `MSHR.scala`
- 2.3 Acquire Path (Cache Miss → TileLink A Channel)
  - Load miss: AcquireBlock(NtoB) — requesting Branch/read permission
  - Store miss: AcquireBlock(NtoT) or AcquirePerm(BtoT) — requesting Trunk/write permission
  - Message construction: opcode, param, address, size, source
  - Arbitration when multiple MSHRs compete for Channel A
  - Key source references in DCache acquire logic
- 2.4 Grant Path (TileLink D Channel → Fill DCache)
  - Receiving Grant/GrantData from L2
  - Data fill into data array, tag update, meta state transition
  - GrantAck generation (Channel E) to complete three-hop handshake
  - Multi-beat Grant handling and refill buffer
  - Key source references in DCache grant/refill logic
- 2.5 Probe Handling (TileLink B Channel → Snoop DCache)
  - `ProbeQueue` or probe handling unit
  - Probe processing: tag lookup, state check, data read if dirty
  - ProbeAck/ProbeAckData generation (Channel C)
  - Permission downgrade: T→B, T→N, B→N
  - Probe-miss handling (line not present)
  - Interaction with in-flight MSHR transactions
  - Key source references in DCache probe logic
- 2.6 Voluntary Release (Eviction → TileLink C Channel)
  - When DCache initiates a Release: eviction, capacity miss, replacement
  - ReleaseData (dirty writeback) vs. Release (clean drop with notification)
  - Release state transitions and source ID usage
  - ReleaseAck reception (Channel D) and MSHR completion
  - Key source references in DCache release/writeback logic
- 2.7 DCache Coherence State Encoding
  - Meta state bits in DCache tag array
  - Mapping to TileLink permissions (N, B, T)
  - State transition table: all DCache meta states × events → new state + TileLink message
  - Key source references for state definitions and transitions

### 3. CoupledL2: TileLink Slave and Master Implementation
- 3.1 L2 Slice Architecture and TileLink Ports
  - Slice structure: directory, data array, MSHR file, request/response queues
  - Inner TileLink slave port (facing L1 DCache)
  - Outer TileLink master port (facing LLC or memory)
  - Slice selection: address interleaving and hashing
  - Key source references: `CoupledL2.scala`, `Slice.scala`
- 3.2 Directory and Coherence State Tracking
  - Directory entry format: tag, state, client bitvector, dirty bit
  - Self-directory (L2 line state) vs. client-directory (L1 permission tracking)
  - State encoding at L2 level
  - Directory lookup pipeline
  - Key source references: `Directory.scala`, `SelfDirectory.scala`, `ClientDirectory.scala`
- 3.3 Request Processing Pipeline
  - Request buffer and arbitration (inner A, inner C, outer D)
  - MSHR allocation for coherence transactions
  - Pipeline stages: directory read → state check → action decision → execution
  - Key source references: `RequestArb.scala`, `MainPipe.scala`
- 3.4 Handling Acquire from L1 (Inner Channel A → Processing)
  - AcquireBlock/AcquirePerm reception and buffering
  - Directory lookup: hit vs. miss, permission check
  - **Hit with sufficient permission:** direct Grant/GrantData on inner Channel D
  - **Hit with insufficient permission:** allocate MSHR, may Probe other L1 clients
  - **Miss:** allocate MSHR, issue outer Acquire on outer Channel A
  - Replacement victim selection if set is full
  - Key source references in L2 Acquire handling
- 3.5 Probing L1 Clients (Inner Channel B → Probe)
  - When L2 needs to downgrade/invalidate an L1 copy
  - Probe generation: address, parameter (toN, toB, toT)
  - Waiting for ProbeAck/ProbeAckData on inner Channel C
  - Merging dirty data from ProbeAck into L2 data array
  - Handling multiple L1 clients (multi-core L2 slice)
  - Key source references in L2 Probe logic
- 3.6 Outer TileLink Transactions (L2 as Master)
  - When L2 issues Acquire on outer Channel A (L2 miss)
  - Receiving Grant/GrantData on outer Channel D
  - Sending GrantAck on outer Channel E
  - Voluntary Release on outer Channel C (L2 eviction to LLC)
  - Receiving Probe on outer Channel B (LLC probing L2)
  - Key source references in L2 outer-edge logic
- 3.7 Grant and ReleaseAck Back to L1 (Inner Channel D)
  - Constructing Grant/GrantData responses
  - Sink ID allocation for three-hop tracking
  - Waiting for GrantAck on inner Channel E
  - ReleaseAck for L1-initiated releases
  - Key source references in L2 response logic
- 3.8 MSHR Lifecycle in L2
  - MSHR allocation triggers and states
  - Nested transaction handling: outer Acquire inside inner Acquire processing
  - MSHR state machine: overview of states and transitions
  - Conflict detection: same-address requests while MSHR is active
  - MSHR deallocation and resource cleanup
  - Key source references: `MSHR.scala` in CoupledL2

### 4. End-to-End Transaction Traces
- 4.1 Trace 1: L1 Load Miss (Cold Miss)
  - Load pipeline detects miss → MSHR allocated → AcquireBlock(NtoB)
  - L2 directory miss → outer AcquireBlock → LLC GrantData → L2 fill
  - L2 inner GrantData → L1 refill → GrantAck
  - Annotated cycle-by-cycle trace with channel activity
- 4.2 Trace 2: L1 Store Miss with Upgrade
  - Store hits L1 in Branch state → AcquirePerm(BtoT)
  - L2 has line in Trunk → Probes other L1 sharers → ProbeAck(BtoN)
  - L2 Grant(toT) → L1 upgrades to Trunk → GrantAck
  - Annotated trace
- 4.3 Trace 3: L1 Eviction (Dirty Writeback)
  - L1 replacement selects dirty line → ReleaseData(TtoN)
  - L2 receives dirty data → updates data array and directory → ReleaseAck
  - Annotated trace
- 4.4 Trace 4: L2 Eviction with L1 Back-Invalidation
  - L2 capacity miss → must evict line held by L1
  - L2 Probes L1 → L1 ProbeAckData → L2 outer ReleaseData to LLC
  - LLC ReleaseAck → L2 MSHR completes
  - Annotated trace
- 4.5 Trace 5: Concurrent Access Race
  - Two L1s (different cores sharing L2) access same line simultaneously
  - Race resolution at L2 directory: serialization, one request NAcked or buffered
  - Annotated trace showing the ordering

### 5. Parameterization and Configuration
- 5.1 DCache TileLink Parameters
  - Number of MSHRs, source ID space
  - Refill buffer depth, probe queue depth
  - AcquireBlock vs. AcquirePerm policy decisions
  - Parameter table with links to source definitions
- 5.2 CoupledL2 TileLink Parameters
  - Number of slices, ways, sets
  - MSHR count per slice
  - Inner/outer edge widths
  - Inclusive vs. non-inclusive policy setting
  - Parameter table with links to source definitions
- 5.3 Bus Configuration and Address Mapping
  - TileLink bus width at each level
  - Address range assignment and interleaving
  - Source/sink ID space partitioning

### 6. Worked Example: Tracing a Transaction in RTL
- Start with a program snippet (two cores accessing shared data)
- Show expected TileLink transactions
- Point to exact RTL modules and signals for each step
- Cross-reference with waveform dump methodology (Appendix E)

### 7. Design Trade-Off: XiangShan's Coherence Choices
- Why private L2 per core (not shared L2)?
- Inclusive vs. non-inclusive L2 policy trade-offs in XiangShan
- TileLink for inner coherence vs. CHI for outer — boundary rationale
- MSHR count and concurrency vs. area/complexity

### 8. Key Takeaways
- 5 bullet points summarizing XiangShan's TileLink implementation

### 9. Checkpoint Questions
- 8 questions at Basic / Intermediate / Advanced levels

### 10. Further Reading
- XiangShan Design Documentation on cache hierarchy (`XiangShan-Design-Doc/`)
- CoupledL2 README and design documentation
- Chapters 20–23 (Load/Store/DCache) in the main text
- Chapter 26 (L2 Cache) in the main text
- Chapter 28 (Coherence Protocol) in the main text
- SiFive TileLink spec (for protocol baseline, see I.2)

---

## Diagrams Planned

1. **Block diagram:** XiangShan two-level TileLink coherence hierarchy (L1 ↔ L2 ↔ LLC)
2. **Block diagram:** DCache TileLink interface — MSHRs, probe queue, channel connections
3. **Block diagram:** CoupledL2 slice internals — directory, data array, MSHR file, request pipeline
4. **Sequence diagram:** Trace 1 — L1 cold miss, full transaction across all five channels
5. **Sequence diagram:** Trace 2 — Store upgrade with Probe to other sharer
6. **Sequence diagram:** Trace 3 — L1 dirty eviction / writeback
7. **Sequence diagram:** Trace 4 — L2 eviction with L1 back-invalidation
8. **Sequence diagram:** Trace 5 — Concurrent access race resolution
9. **FSM diagram:** DCache MSHR state machine (TileLink transaction states)
10. **FSM diagram:** CoupledL2 MSHR state machine
11. **Pipeline diagram:** L2 request processing pipeline stages
12. **State transition table diagram:** DCache meta states × events → new state + TileLink action

## Tables Planned

1. DCache TileLink source ID allocation table
2. DCache coherence meta state encoding (with permission mapping)
3. DCache state transition table (state × event → action)
4. CoupledL2 directory entry format
5. CoupledL2 self-directory state encoding
6. CoupledL2 client-directory state encoding
7. CoupledL2 MSHR state descriptions
8. DCache TileLink parameter table (with links to source)
9. CoupledL2 TileLink parameter table (with links to source)
10. End-to-end latency summary for each transaction type
