# Chapter 29. OpenLLC — The CHI Home Node (HN-F)

<!-- Status: Detailed plan — content to be written -->

---

## Purpose

This chapter covers OpenLLC, XiangShan's CHI-native last-level cache that serves
as the Home Node (HN-F). OpenLLC is the Point-of-Coherence in the system: it
maintains the directory (snoop filter), resolves coherence conflicts, issues snoops,
and bridges to memory through the SN-F. This is the most complex CHI node in
XiangShan and the heart of the coherence fabric.

**Prerequisites:** Chapter 27 (CHI protocol), Chapter 28 (CoupledL2 as RN-F).

---

## Table of Contents

### 1. Motivation and Design Context

1.1. Why a CHI-Native L3?
   - HuanCun (TileLink L3) served earlier XiangShan generations
   - OpenLLC replaces HuanCun when `EnableCHI = true`
   - Benefits: native CHI support avoids TL↔CHI bridge at LLC level
   - Configuration: `OpenLLCParamsOpt` vs. `L3CacheParamsOpt` — mutually exclusive
   - Source: [`SoC.scala:130-132`](src/main/scala/system/SoC.scala#L130) — assertion enforcing exclusivity

1.2. OpenLLC in the System
   - Block diagram: N × RN-F → OpenLLC (HN-F) → SN-F → AXI4 memory
   - Default CHIConfig: 16MB, 4 banks, 16-way associative
   - Source: [`OpenLLC.scala`](openLLC/src/main/scala/openLLC/OpenLLC.scala)

1.3. Inclusion Policy
   - With 1 RN: exclusive (data in L2 XOR LLC, not both)
   - With multiple RNs: non-inclusive (directory tracks presence, data may be in both)
   - Why this matters: back-invalidation policy, effective capacity

### 2. Top-Level Architecture

2.1. OpenLLC Block Diagram
   - N RN ports (one per CoupledL2) → RNLinkMonitors → RNXbar
   - RNXbar → 4 Slices (address-interleaved banks)
   - 4 Slices → SNXbar → SNLinkMonitor → 1 SN port
   - MMIO bypass: MMIODiverger (before slices) and MMIOMerger (after)

2.2. RNXbar: Request Routing
   - Address-based bank selection (hash of address bits)
   - Arbitration across N RN-F inputs per bank
   - Snoop broadcast: HN sends snoops to all RN-F nodes (with mask filtering)
   - Source: [`CHIXbar.scala`](openLLC/src/main/scala/openLLC/utils/CHIXbar.scala)

2.3. SNXbar: Response Demultiplexing
   - TxnID-based routing: matches responses from SN-F back to originating slice
   - Single SN-F output port (all slices share the memory interface)

2.4. MMIO Path
   - MMIODiverger: separates non-cacheable requests before they reach slices
   - MMIO requests forwarded directly to SN-F (ReadNoSnp, WriteNoSnp)
   - MMIOMerger: recombines cache and MMIO responses
   - Source: [`MMIOBridge.scala`](openLLC/src/main/scala/openLLC/utils/MMIOBridge.scala)

### 3. Slice Internals

3.1. Slice Block Diagram
   - Input: CHI channels from RNXbar (upstream) and SNXbar (downstream)
   - RequestBuffer → RequestArb → MainPipe → functional units → response channels
   - Directory (tag + state array) and DataStorage (SRAM data array)
   - Source: [`Slice.scala`](openLLC/src/main/scala/openLLC/Slice.scala)

3.2. RequestBuffer and Arbitration
   - Incoming requests buffered and checked for address conflicts
   - RequestArb selects between new requests, MSHR replays, and snoop responses
   - Conflict detection: prevents two transactions on the same address from
     entering the pipeline simultaneously

3.3. MainPipe: Multi-Stage Pipeline
   - Stage breakdown: tag lookup → directory read → state decision →
     data read/write → response generation
   - Hazard handling: pipeline stalls when data/response resources are busy
   - Source: [`MainPipe.scala`](openLLC/src/main/scala/openLLC/MainPipe.scala)

3.4. Directory: Tag and State Array
   - Per-line entry: tag, coherence state, sharer bit-vector (one bit per RN-F)
   - CHI states tracked: I (Invalid), SC (Shared Clean), UC (Unique Clean),
     UD/PD (Unique Dirty / Partial Dirty), SD (Shared Dirty)
   - Snoop filter semantics: directory only tracks lines present in at least one RN-F cache
   - Replacement policy for directory entries on conflict miss

3.5. DataStorage
   - SRAM array holding cache line data
   - Accessed on cache hit (read data), refill (write data), and eviction (read for write-back)
   - Banked for bandwidth

### 4. Coherence State Tracking

4.1. Directory States and Transitions
   - State diagram: I ↔ SC ↔ UC ↔ UD, with snoop-driven transitions
   - How sharer bit-vector is updated on each transaction type
   - When dirty responsibility transfers between RN-F and HN-F

4.2. Snoop Filter Behavior
   - On read miss (line not in directory): allocate entry, fetch from SN-F
   - On read hit (line in another RN-F): may need snoop to downgrade/invalidate
   - On eviction notification (Evict from RN-F): clear sharer bit, possibly deallocate

4.3. Comparison with Full Directory
   - OpenLLC's snoop filter only tracks cached lines (not all of memory)
   - On filter miss: line guaranteed not in any RN-F — no snoop needed
   - On filter eviction: must back-invalidate the tracked RN-F copy

### 5. Transaction Processing Walkthroughs

5.1. ReadUnique: L2 Write Miss, Line in Another L2
   - RN-F₀ sends ReadUnique → HN-F directory shows line in RN-F₁ (SC)
   - HN-F sends SnpUnique to RN-F₁ → RN-F₁ invalidates, returns SnpResp(I)
   - HN-F sends CompData(UD) to RN-F₀ → RN-F₀ sends CompAck
   - Directory update: clear RN-F₁ bit, set RN-F₀ bit, state → UD
   - Sequence diagram with all messages

5.2. WriteBackFull: L2 Evicts Dirty Line
   - RN-F sends WriteBackFull → HN-F returns CompDBIDResp
   - RN-F sends CopyBackWrData → HN-F writes data to DataStorage
   - Directory update: clear sharer bit, update state to I or SC
   - If data needs to go to memory: HN-F issues WriteNoSnp to SN-F

5.3. MakeUnique: Permission Upgrade (Shared → Unique)
   - RN-F₀ holds line SC, wants to write → sends MakeUnique
   - HN-F snoops all other sharers with SnpMakeInvalid
   - After all SnpResp(I) received: HN-F sends Comp(UC) to RN-F₀
   - No data transfer needed — RN-F₀ already has the data

5.4. Evict: Silent Clean Eviction
   - RN-F drops a clean shared line → sends Evict to HN-F
   - HN-F clears the sharer bit in directory, sends Comp
   - No data movement

5.5. ReadShared: Multiple Sharers Scenario
   - Line already in SC at RN-F₀, RN-F₁ also wants SC
   - HN-F directory lookup → no snoop needed (line is clean, shareable)
   - HN-F sends CompData(SC) to RN-F₁, adds RN-F₁ to sharer vector

### 6. Functional Units

6.1. SnoopUnit
   - Generates TXSNP messages when MainPipe determines snoops are needed
   - Tracks outstanding snoops and collects responses
   - Snoop type selection based on request type and current directory state

6.2. MemUnit
   - Issues downstream requests to SN-F: ReadNoSnp (fetch from memory),
     WriteNoSnp (write-back to memory)
   - Tracks outstanding memory transactions
   - Handles data return path from SN-F

6.3. RefillUnit
   - Manages pending memory read completions
   - When SN-F returns data (RXDAT), RefillUnit writes it to DataStorage
     and triggers response to the requesting RN-F

6.4. ResponseUnit
   - Schedules upstream responses: Comp, CompData, CompDBIDResp
   - Arbitrates between multiple pending responses from the same slice

### 7. CHI Link Layer in OpenLLC

7.1. RNLinkMonitor (Per-RN Connection)
   - Manages link state machine: STOP → ACTIVATE → RUN → DEACTIVATE
   - Tracks L-Credit counters for each TX channel (TXRSP, TXDAT, TXSNP)
   - Receives credits from each RX channel (RXREQ, RXRSP, RXDAT)
   - Source: [`LinkLayer.scala`](openLLC/src/main/scala/openLLC/chi/LinkLayer.scala)

7.2. SNLinkMonitor (SN Connection)
   - Same state machine, but for the downstream SN-F interface
   - Manages credits for TXREQ, TXDAT (to memory) and RXRSP, RXDAT (from memory)

### 8. Worked Example: Multi-Core Contention

8.1. Scenario
   - 4-core system, all cores access the same cache line
   - Core 0 reads (ReadShared), Core 1 reads (ReadShared), Core 2 writes (ReadUnique)

8.2. Cycle-by-Cycle Trace
   - Show OpenLLC directory state after each transaction
   - Sharer bit-vector evolution: `{0}` → `{0,1}` → `{2}` (after snoop invalidation)
   - Total snoop fan-out and latency analysis

8.3. Conflict Handling
   - What happens if Core 3 sends ReadUnique while Core 2's snoop is in flight?
   - RequestBuffer conflict detection and serialization

### 9. Performance Monitoring

9.1. TopDown Monitor
   - L3 miss reporting for top-down performance analysis
   - Integration with XiangShan's performance counter framework

9.2. CHI Logger
   - Transaction logging for debug and analysis
   - How to correlate with FST waveforms

### 10. Design Trade-Offs

10.1. Crossbar vs. Ring for Bank Interconnect
   - OpenLLC uses a crossbar (RNXbar/SNXbar) — O(N×B) complexity
   - Sufficient for 4 RN-F × 4 banks; may not scale to 16+ cores
   - Ring alternative: higher latency, better wire scaling

10.2. Non-Inclusive vs. Inclusive LLC
   - Non-inclusive maximizes effective capacity (no duplicate data in LLC)
   - Inclusive simplifies snoop filter (guaranteed superset of L2 contents)
   - OpenLLC's choice: non-inclusive with explicit eviction tracking

10.3. CHI Subset vs. Full Protocol
   - OpenLLC implements ~11 of 50+ CHI request opcodes
   - Omitted: atomics, DVM, stash, cache maintenance, snoop forwarding
   - Trade-off: simpler verification and lower area vs. future feature needs

10.4. Snoop Broadcast vs. Directed Snoops
   - OpenLLC uses directed snoops (consults sharer bit-vector)
   - Broadcast fallback on snoop filter eviction
   - Bandwidth and energy implications

### 11. Key Takeaways

1. OpenLLC is the Point-of-Coherence (HN-F): it maintains the directory,
   resolves conflicts, and serializes all coherence transactions.
2. The banked architecture (RNXbar → Slices → SNXbar) provides bandwidth
   scaling through address-interleaved parallelism.
3. The directory (snoop filter) tracks per-line state and a sharer bit-vector
   to issue targeted snoops instead of broadcasts.
4. Five main transaction patterns (ReadUnique, ReadShared, WriteBackFull,
   MakeUnique, Evict) cover XiangShan's coherence needs.
5. The MMIO bypass path (MMIODiverger/MMIOMerger) ensures non-cacheable
   accesses do not pollute the L3 or trigger unnecessary coherence traffic.

### 12. Checkpoint Questions

**Basic:**
1. What is the difference between OpenLLC's role as HN-F and CoupledL2's
   role as RN-F?
2. How does OpenLLC determine which RN-F nodes to snoop for a given request?
3. What happens at the directory when an RN-F sends an Evict message?

**Intermediate:**
4. Trace a ReadUnique through OpenLLC when the line is dirty (UD) in another
   RN-F. Identify every message, directory state change, and data movement.
5. OpenLLC's snoop filter tracks only cached lines. What happens when the
   filter itself is full and needs to evict an entry? Describe the
   back-invalidation flow.

**Advanced:**
6. OpenLLC uses address-based bank interleaving. Analyze the impact of a
   workload where 90% of accesses map to the same bank (e.g., a contended
   lock). What is the throughput bottleneck, and how could bank hashing
   mitigate it?
7. Design an extension to OpenLLC that supports CHI snoop forwarding
   (SnpXFwd). What changes are needed in the SnoopUnit, MainPipe, and
   ResponseUnit? What is the expected latency benefit for cache-to-cache
   transfers?
8. Compare OpenLLC's crossbar interconnect to ARM CMN's mesh. At what core
   count does the crossbar become impractical? Quantify in terms of wire
   count and arbitration delay.

### 13. Further Reading

1. OpenLLC source: `openLLC/src/main/scala/openLLC/`
2. Chapter 27 of this book — CHI protocol and transaction flows
3. Chapter 28 — CoupledL2 (the RN-F that talks to OpenLLC)
4. Chapter 30 — OpenNCB (the SN-F that OpenLLC delegates to for memory access)
5. ARM, *AMBA CHI Architecture Specification* — Home Node transaction rules
