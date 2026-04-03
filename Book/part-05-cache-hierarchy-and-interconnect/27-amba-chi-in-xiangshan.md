# Chapter 27. AMBA CHI in XiangShan

<!-- Status: Detailed plan — content to be written -->

---

## Purpose

This chapter introduces the AMBA CHI (Coherent Hub Interface) protocol as
implemented in XiangShan's `CHIConfig`. It covers the protocol's layered
architecture, node types, channel structure, and transaction model — focused on
the subset that XiangShan actually uses. The reader should finish this chapter
able to read a CHI transaction trace from the Verilator simulation (Chapter 26's
FST waveform) and understand every message.

**Prerequisites:** Chapter 26 (directory coherence and NoC concepts).

---

## Table of Contents

### 1. Motivation: Why CHI for XiangShan?

1.1. From TileLink to CHI: The Scaling Decision
   - TileLink (TL-C) serves XiangShan well at 1-2 cores
   - CHI designed from the ground up for 4-64+ core coherent systems
   - The `EnableCHI` config flag: two protocol stacks in one codebase

1.2. CHI in the AMBA Family
   - AXI (non-coherent, point-to-point) → ACE (coherent extension) → CHI
   - CHI as a packet-based replacement for ACE's shared-bus model
   - Issue versions: B (baseline), C (adds atomics), E.b (adds MPAM, cleansharedpersist)
   - XiangShan supports B, C, and E.b — configurable via `ISSUE` build parameter

1.3. XiangShan's CHI System at a Glance
   - Block diagram: Cores → CoupledL2 (RN-F) → OpenLLC (HN-F) → OpenNCB (SN-F) → AXI4 memory
   - ASCII "Read This First" diagram comparing TLConfig vs. CHIConfig data paths
   - Key source:
     [`Top.scala`](src/main/scala/top/Top.scala) — CHI instantiation
     [`Configs.scala`](src/main/scala/top/Configs.scala) — CHIConfig definition

### 2. CHI Layered Architecture

2.1. Three Layers: Protocol, Network, Link
   - Protocol layer: transaction semantics, coherence rules, ordering
   - Network layer: routing, node addressing, topology abstraction
   - Link layer: flit transfer, credit management, physical signaling
   - Diagram: layer stack with XiangShan modules mapped to each layer

2.2. Why Layering Matters for XiangShan
   - XiangShan implements Protocol and Link layers directly
   - Network layer is a simple crossbar in OpenLLC (no general-purpose NoC yet)
   - Future scaling (XSNoCTop) adds a real network layer

### 3. Node Types

3.1. Request Node — Fully Coherent (RN-F)
   - Initiates coherent transactions (reads, writes, atomics)
   - Maintains cache state, responds to snoops
   - In XiangShan: CoupledL2 (one RN-F per core)
   - CHI port interface:
     [`PortIO`](coupledL2/src/main/scala/coupledL2/tl2chi/chi/LinkLayer.scala)

3.2. Home Node — Fully Coherent (HN-F)
   - Point-of-Coherence: resolves coherence state for every request
   - Maintains the snoop filter / directory
   - Issues snoops to RN-F nodes, serializes conflicting requests
   - In XiangShan: OpenLLC (one HN-F, banked into slices)
   - Key source:
     [`OpenLLC.scala`](openLLC/src/main/scala/openLLC/OpenLLC.scala)

3.3. Slave Node — Fully Coherent (SN-F)
   - Non-coherent endpoint: memory controller or bridge
   - Accepts ReadNoSnp/WriteNoSnp from HN-F (no snoops, no cache state)
   - In XiangShan: OpenNCB bridge (CHI → AXI4)
   - Key source:
     [`OpenNCB.scala`](openLLC/src/main/scala/openLLC/utils/OpenNCB.scala)

3.4. Node Diagram
   - Mermaid diagram: RN-F ↔ HN-F ↔ SN-F with channel annotations
   - Node ID assignment in XiangShan (per CHI issue version)

### 4. Channels and Flit Format

4.1. Six Logical Channels
   - **REQ** (TX: RN→HN): Read/Write/Evict requests
   - **RSP** (TX: RN→HN, also HN→RN): Completion acknowledgments
   - **DAT** (TX: bidirectional): Cache line data with coherence metadata
   - **SNP** (TX: HN→RN): Snoop/invalidate commands
   - Upstream vs. downstream: naming convention (TX = sender transmits)
   - Table: channel name, direction, flit type, width

4.2. Key Flit Fields
   - `TxnID`: transaction identifier (assigned by requester)
   - `DBID`: data buffer identifier (assigned by completer)
   - `Opcode`: transaction type within each channel
   - `Addr`: physical address (REQ and SNP channels)
   - `Resp`: coherence state in response (CHI cache state encoding)
   - `Data`: 256-bit (32-byte) or 512-bit data payload (DAT channel)
   - `BE`: byte enable for partial writes
   - Source references:
     [`Message.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/chi/Message.scala)

4.3. Credit-Based Flow Control (L-Credits)
   - Each channel has a credit pool (configurable depth, max 15)
   - Sender decrements credit before sending a flit
   - Receiver returns credits as buffer space frees
   - Link layer implementation:
     [`LinkLayer.scala`](openLLC/src/main/scala/openLLC/chi/LinkLayer.scala)

### 5. CHI Transactions: The XiangShan Subset

5.1. Coherent Read Transactions
   - `ReadShared`: request shared copy (may get exclusive if sole requester)
   - `ReadUnique`: request exclusive copy for write (invalidates other sharers)
   - `ReadNotSharedDirty`: request clean copy, don't accept dirty transfer
   - `ReadOnce`: non-cacheable read (no state allocated)

5.2. Dataless Transactions
   - `MakeUnique`: upgrade from Shared to Unique (no data transfer needed)
   - `Evict`: notify HN that a clean line was silently dropped
   - `CleanUnique`: similar to MakeUnique, for specific upgrade scenarios

5.3. Write-Back Transactions
   - `WriteBackFull`: write dirty line back to HN (voluntary or forced)
   - Comp/CompDBIDResp handshake: HN acknowledges and provides buffer ID

5.4. Snoop Transactions (HN → RN)
   - `SnpShared`: downgrade owner to Shared state, return data
   - `SnpUnique`: invalidate, return data if dirty
   - `SnpSharedFwd` / `SnpUniqueFwd`: snoop with forwarding hint (E.b)
   - `SnpNotSharedDirtyFwd`: don't transfer dirty responsibility

5.5. Response and Completion
   - `Comp`: completion without data
   - `CompData`: completion with data (combined response+data)
   - `CompDBIDResp`: completion with data buffer allocation
   - `CompAck`: requester's final acknowledgment (three-message handshake)

5.6. Transaction Flow Diagrams
   - Sequence diagram: ReadUnique with snoop (RN-F₁ → HN-F → RN-F₀ → RN-F₁)
   - Sequence diagram: WriteBackFull (RN-F → HN-F → SN-F)
   - Sequence diagram: MakeUnique (RN-F → HN-F, broadcast snoop, Comp)

### 6. Retry and P-Credit Mechanism

6.1. Why Retry Exists
   - HN may run out of tracking resources (MSHR slots)
   - Rather than stalling the link, HN returns RetryAck
   - Requester must wait for PCrdGrant before retrying

6.2. Retry Flow
   - RN sends REQ → HN returns RetryAck (transaction not accepted)
   - HN later sends PCrdGrant → RN retries with PCrdType matching
   - Implementation in CoupledL2:
     [`RXRSP.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/RXRSP.scala) — PCredit handling

### 7. Link Layer State Machine

7.1. Four States: STOP → ACTIVATE → RUN → DEACTIVATE
   - STOP: link inactive, no credits exchanged
   - ACTIVATE: handshake, initial credit exchange
   - RUN: normal operation, flits and credits flowing
   - DEACTIVATE: drain in-flight flits, return to STOP

7.2. Implementation
   - [`LinkLayer.scala`](openLLC/src/main/scala/openLLC/chi/LinkLayer.scala) — RNLinkMonitor, SNLinkMonitor
   - Link state tracked per RN connection and per SN connection

### 8. Worked Example: ReadUnique Through the Full Stack

8.1. Scenario
   - Core 0 stores to address X (L1 miss, L2 miss)
   - Core 1 holds X in Shared state in its L2
   - Trace through CoupledL2 → OpenLLC → Snoop to Core 1's L2 → CompData → CompAck

8.2. Message-by-Message Trace
   - Table: cycle | sender | channel | opcode | key fields | next state
   - 12-15 messages from initial REQ to final CompAck

8.3. Waveform Correlation
   - How to find these signals in the CHIConfig FST trace
   - Key signal paths: `SimTop.cpu.l_soc.core_with_l2.l2top.inner.l2cache.slices_*`
   - OpenLLC signals: `SimTop.cpu.l_soc.llc.*`

### 9. CHI vs. TileLink: A Structural Comparison

9.1. Channel Structure
   - TileLink: 5 channels (A-E) with interleaved request/response semantics
   - CHI: 4 channel types with clear role separation (REQ/SNP/RSP/DAT)

9.2. Scalability Model
   - TileLink: assumes shared interconnect (crossbar or bus)
   - CHI: point-to-point with credit flow, designed for NoC routing

9.3. Coherence Model
   - TileLink: 4 states (N/B/T/F), permission-based
   - CHI: 5 states (I/SC/UC/UD/SD), explicit dirty tracking

9.4. Transaction Complexity
   - CHI's retry/credit mechanism vs. TileLink's simpler deny
   - CHI's three-message handshake (CompAck) vs. TileLink's Grant/GrantAck

### 10. Common Misconceptions

- **"CHI is just AXI with coherence."** CHI is a fundamentally different protocol
  from AXI. It uses packet-based flits instead of AXI's channel handshakes, has
  its own flow control (L-Credits), and supports multi-hop transactions.

- **"Every CHI transaction requires a snoop."** Read requests to lines in Invalid
  state at all RN-F nodes require no snoops — the HN-F serves directly from
  memory or its own data store.

- **"CompAck is optional."** In XiangShan's CHI implementation, the three-message
  handshake (Request → CompData → CompAck) is required for coherent reads.
  CompAck tells the HN-F it can safely deallocate the tracking entry.

### 11. Key Takeaways

1. CHI separates protocol, network, and link concerns — XiangShan implements
   protocol and link directly, with a crossbar standing in for the network layer.
2. Three node types partition responsibility: RN-F (requester/cache), HN-F
   (coherence home/directory), SN-F (memory endpoint).
3. Four channel types (REQ, SNP, RSP, DAT) with credit-based flow control
   enable point-to-point communication without shared-bus bottlenecks.
4. XiangShan implements a focused CHI subset (~11 request opcodes, ~5 snoop
   opcodes) sufficient for its coherence needs.
5. The retry/P-credit mechanism lets the home node gracefully handle resource
   exhaustion without stalling the link.

### 12. Checkpoint Questions

**Basic:**
1. Name the three CHI node types and state which XiangShan module implements each.
2. What is the difference between the REQ and SNP channels in terms of direction
   and purpose?
3. What does an L-Credit represent, and what happens if a sender runs out?

**Intermediate:**
4. Walk through the message sequence for a ReadShared that hits in the OpenLLC
   directory with no other sharers. How many messages total?
5. Why does CHI need a separate CompAck message? What race condition does it
   prevent at the home node?
6. Compare how XiangShan handles an L2 write miss under TLConfig vs. CHIConfig.
   Identify the corresponding messages in each protocol.

**Advanced:**
7. The retry mechanism adds latency to requests that arrive when the HN-F is
   full. Design a fairness policy for PCrdGrant that prevents starvation of
   one RN-F by another. What information does the HN-F need to track?
8. XiangShan's CHI subset omits atomic transactions. Describe how a
   compare-and-swap on a shared variable is implemented using the existing
   ReadUnique + WriteBackFull primitives. What are the performance implications
   compared to native CHI atomics?

### 13. Further Reading

1. ARM, *AMBA CHI Architecture Specification* (Issue E.b, 2023) — the
   authoritative protocol reference.
2. ARM, *AMBA 5 CHI Protocol Overview* — concise summary of node types
   and transactions.
3. Chapter 26 of this book — directory coherence and NoC concepts.
4. Chapter 28 — CoupledL2 as the RN-F implementation.
5. Chapter 29 — OpenLLC as the HN-F implementation.
