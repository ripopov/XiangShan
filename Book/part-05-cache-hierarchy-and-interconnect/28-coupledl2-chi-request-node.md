# Chapter 28. CoupledL2 — The CHI Request Node (RN-F)

<!-- Status: Detailed plan — content to be written -->

---

## Purpose

This chapter covers the CoupledL2 module as XiangShan's CHI Request Node (RN-F).
CoupledL2 is a TileLink-to-CHI bridge that wraps the L2 cache: it accepts TileLink
requests from the L1 caches and issues CHI transactions toward the OpenLLC home
node. This chapter explains the bridge architecture, the CHI channel implementation,
MSHR-to-CHI transaction mapping, and the MMIO bypass path.

**Prerequisites:** Chapter 27 (CHI protocol, channels, transactions).

---

## Table of Contents

### 1. Motivation and Context

1.1. CoupledL2's Dual Role
   - An L2 cache for the core (TileLink-facing, covered in Part IV from the core's view)
   - A CHI Request Node (RN-F) for the coherence fabric (this chapter's focus)
   - The TL2CHI bridge layer: translating TileLink Acquire/Release into CHI REQ/SNP/RSP/DAT

1.2. Where CoupledL2 Sits in the CHIConfig Hierarchy
   - Block diagram: Core (TL-C) → CoupledL2 (TL-C ↔ CHI RN-F) → OpenLLC (HN-F)
   - One CoupledL2 instance per core, each with a unique CHI Node ID
   - Configuration: 1MB, 4-way banked, inclusive L2

1.3. Key Source Files
   - [`TL2CHICoupledL2.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/TL2CHICoupledL2.scala) — top-level TL-to-CHI wrapper
   - [`Slice.scala`](coupledL2/src/main/scala/coupledL2/Slice.scala) — per-bank slice with MSHR logic
   - [`chi/LinkLayer.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/chi/LinkLayer.scala) — PortIO and link definitions

### 2. Top-Level Architecture

2.1. TL2CHICoupledL2 Block Diagram
   - Internal: 4 cache slices, each with MSHRs, directory, data array
   - External: one CHI PortIO (6 channels) toward HN-F
   - MMIO path: separate MMIOBridge for non-cacheable accesses

2.2. CHI Port Interface (PortIO)
   - TX channels (L2 → HN): TXREQ, TXRSP, TXDAT
   - RX channels (HN → L2): RXSNP, RXRSP, RXDAT
   - SysCoReq / SysCoAck: system coherency handshake
   - Source: [`LinkLayer.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/chi/LinkLayer.scala)

2.3. Decoupled vs. L-Credit Interface
   - Internally, slices use Decoupled (valid/ready) handshake
   - LinkMonitor converts Decoupled ↔ L-Credit at the CHI port boundary
   - Credit depth configuration and back-pressure behavior

### 3. TX Channel Implementation

3.1. TXREQ: Request Arbitration
   - Multiple slices compete to send requests (ReadShared, ReadUnique, WriteBackFull, etc.)
   - MMIO bridge also competes for TXREQ bandwidth
   - Arbitration policy: round-robin across slices + MMIO
   - TxnID encoding: MSB distinguishes cache vs. MMIO transactions
   - Source: [`TXREQ.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/TXREQ.scala)

3.2. TXRSP: Response Transmission
   - CompAck sent after receiving CompData from HN
   - SnpResp sent in response to incoming snoops
   - Source: [`TXRSP.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/TXRSP.scala)

3.3. TXDAT: Data Transmission
   - WriteBackFull data (dirty eviction from L2)
   - SnpRespData: data returned in response to snoops when line is dirty
   - CopyBackWrData: write data following CompDBIDResp
   - Source: [`TXDAT.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/TXDAT.scala)

### 4. RX Channel Implementation

4.1. RXSNP: Snoop Distribution
   - Incoming snoops from HN-F (SnpShared, SnpUnique, etc.)
   - Address-based routing to the correct slice (bank selection)
   - Snoop must check L2 directory and data, may need to write back
   - Source: [`RXSNP.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/RXSNP.scala)

4.2. RXRSP: Response Handling and P-Credit Management
   - CompAck from HN confirming write-back accepted
   - RetryAck + PCrdGrant: retry flow when HN is busy
   - PCrdGrant tracking: per-PcrdType credit counters
   - Response demultiplexing: TxnID → slice routing
   - Source: [`RXRSP.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/RXRSP.scala)

4.3. RXDAT: Data Reception
   - CompData: read completion data from HN (with coherence state in Resp field)
   - Data routing: TxnID → originating slice and MSHR
   - Source: [`RXDAT.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/RXDAT.scala)

### 5. TileLink-to-CHI Transaction Mapping

5.1. TL Acquire → CHI Request
   - TL AcquireBlock (NtoB) → CHI ReadShared
   - TL AcquireBlock (NtoT) → CHI ReadUnique
   - TL AcquirePerm (BtoT) → CHI MakeUnique
   - Mapping table: TL message type → CHI opcode → expected CHI response

5.2. TL Release → CHI Write-Back
   - TL ReleaseData (TtoN, dirty) → CHI WriteBackFull
   - TL Release (TtoN, clean) → CHI Evict
   - CompDBIDResp + CopyBackWrData handshake for write-backs

5.3. TL Probe Response → CHI Snoop Response
   - HN snoop arrives → L2 converts to TL Probe down to L1 → collects ProbeAck
   - Then L2 sends CHI SnpResp (clean) or SnpRespData (dirty) upstream

5.4. Transaction State Machine
   - MSHR states mapped to CHI transaction phases
   - State diagram: Idle → REQ sent → waiting RSP/DAT → CompAck → Done

### 6. MMIO Bridge

6.1. Non-Cacheable Access Path
   - MMIO requests bypass the L2 cache entirely
   - Separate TxnID namespace (MSB = 1) to distinguish from cache traffic
   - Source: [`MMIOBridge.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/MMIOBridge.scala)

6.2. MMIO Transaction Flow
   - ReadNoSnp for MMIO loads, WriteNoSnpFull for MMIO stores
   - No coherence state management — transactions go directly to SN-F

### 7. Async Bridge (Optional Clock Domain Crossing)

7.1. When It Is Used
   - `EnableCHIAsyncBridge` parameter enables async FIFO crossing
   - Used when L2 and interconnect are in different clock domains

7.2. Implementation
   - [`AsyncBridge.scala`](coupledL2/src/main/scala/coupledL2/tl2chi/chi/AsyncBridge.scala)
   - CHIAsyncBridgeSource (L2 side) ↔ CHIAsyncBridgeSink (NoC side)
   - Configurable queue depth and synchronization stages

### 8. Worked Example: L2 Read Miss → CHI ReadUnique

8.1. Scenario
   - Core 0 executes `sd x5, 0(x10)` — store miss in L1 and L2
   - No other core holds this line

8.2. Step-by-Step Trace
   - L1 sends TL AcquireBlock (NtoT) to L2
   - L2 MSHR allocates, slice sends CHI ReadUnique via TXREQ
   - OpenLLC directory lookup: line in Invalid → fetch from memory via SN-F
   - SN-F returns data → OpenLLC sends CompData to L2 via RXDAT
   - L2 receives data, writes to data array, sends CompAck via TXRSP
   - L2 sends TL GrantData back to L1, L1 sends GrantAck
   - Table: cycle | module | channel | message | key fields

8.3. Retry Scenario Variant
   - Same request, but OpenLLC MSHRs are full → RetryAck
   - L2 waits for PCrdGrant, then retries

### 9. Design Trade-Offs

9.1. Bridge Overhead vs. Protocol Flexibility
   - TL-to-CHI translation adds a few cycles of latency
   - Trade-off: could L2 speak CHI natively? Implications for L1 interface

9.2. Slice-Level vs. Module-Level CHI Port
   - Current: one shared CHI port with arbitration across 4 slices
   - Alternative: one CHI port per slice (more bandwidth, more wires)
   - Why single-port is sufficient given LLC-side bandwidth constraints

9.3. TxnID Space Management
   - Fixed-size TxnID limits outstanding transactions
   - MMIO shares TxnID space via MSB partitioning
   - Trade-off: larger TxnID → more in-flight requests → more MSHR area

### 10. Key Takeaways

1. CoupledL2 acts as XiangShan's RN-F node, translating between TileLink
   (core-facing) and CHI (fabric-facing) protocols.
2. Six CHI channels are implemented through dedicated TX/RX modules, each
   handling arbitration, routing, and credit management.
3. TileLink Acquire/Release messages map systematically to CHI Read/Write/Evict
   transactions through the MSHR state machine.
4. MMIO traffic bypasses the cache via a dedicated bridge with a separate
   TxnID namespace.
5. The retry/P-credit mechanism in RXRSP handles back-pressure from the
   home node without stalling the entire L2.

### 11. Checkpoint Questions

**Basic:**
1. What CHI opcode does CoupledL2 issue for a TileLink AcquireBlock with
   NtoT (need exclusive) permission?
2. Which module converts between Decoupled and L-Credit interfaces at
   the CHI port boundary?
3. How does CoupledL2 distinguish cache transactions from MMIO transactions
   in the TxnID space?

**Intermediate:**
4. When OpenLLC sends a SnpUnique to CoupledL2, describe the internal steps
   L2 performs before sending SnpResp or SnpRespData back.
5. Why does CoupledL2 need to send CompAck after receiving CompData?
   What happens at the HN-F if CompAck is delayed?

**Advanced:**
6. CoupledL2 has 4 slices sharing one TXREQ channel. Analyze the maximum
   throughput (requests per cycle) and identify conditions under which
   TXREQ arbitration becomes a bottleneck.
7. Design an alternative TxnID allocation scheme that dynamically partitions
   IDs between cache and MMIO based on demand. What hardware would be needed,
   and what is the risk of deadlock?
8. If XiangShan moved to per-slice CHI ports (4 independent RN-F nodes per
   core instead of 1), how would OpenLLC's directory and snoop logic need
   to change?

### 12. Further Reading

1. CoupledL2 source: `coupledL2/src/main/scala/coupledL2/`
2. CHI bridge layer: `coupledL2/src/main/scala/coupledL2/tl2chi/`
3. Chapter 27 of this book — CHI protocol fundamentals
4. Chapter 29 — OpenLLC (the HN-F that CoupledL2 talks to)
5. ARM AMBA CHI Architecture Specification — transaction flow diagrams
