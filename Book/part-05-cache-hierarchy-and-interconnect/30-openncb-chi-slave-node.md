# Chapter 30. OpenNCB — The CHI Slave Node and Memory Bridge (SN-F)

<!-- Status: Detailed plan — content to be written -->

---

## Purpose

This chapter covers OpenNCB (Open Non-Coherent Bridge), XiangShan's CHI Slave
Node (SN-F) that bridges the coherence fabric to the AXI4 memory interface.
OpenNCB is the final hop in the CHI hierarchy: it receives non-coherent requests
(ReadNoSnp, WriteNoSnp) from the OpenLLC home node and translates them into
AXI4 read/write bursts to the memory controller.

A secondary set of OpenNCB instances handles MMIO traffic — one per core,
bridging non-cacheable CHI transactions directly to AXI4 device space.

**Prerequisites:** Chapter 27 (CHI protocol), Chapter 29 (OpenLLC as HN-F).

---

## Table of Contents

### 1. Motivation and Context

1.1. The Need for a Protocol Bridge
   - CHI is a coherence protocol; memory controllers speak AXI4
   - SN-F node: the coherence endpoint where CHI transactions terminate
   - No cache state, no snoops — SN-F only sees ReadNoSnp and WriteNoSnp
   - Analogy: the SN-F is a "translator at the border" between the coherent
     world and the non-coherent memory world

1.2. OpenNCB Instances in CHIConfig
   - **LLC bridge**: one OpenNCB between OpenLLC and the memory controller
     - 64 outstanding transactions, odd-parity data check
   - **MMIO bridges**: one OpenNCB per core for MMIO/device access
     - 32 outstanding transactions each
   - Source: [`Top.scala:118-148`](src/main/scala/top/Top.scala#L118) — instantiation

1.3. Key Source Files
   - [`OpenNCB.scala`](openLLC/src/main/scala/openLLC/utils/OpenNCB.scala) — wrapper
   - [`NCB200.scala`](openLLC/openNCB/src/main/scala/openncb/NCB200.scala) — core implementation
   - [`CHISNFInterface.scala`](openLLC/openNCB/src/main/scala/openncb/chi/intf/CHISNFInterface.scala) — CHI SN-F port

### 2. Architecture Overview

2.1. OpenNCB Block Diagram
   - CHI SN-F port (upstream, from HN-F): RXREQ, RXDAT, TXRSP, TXDAT
   - AXI4 Master port (downstream, to memory controller): AR, R, AW, W, B
   - Internal: transaction queue, payload storage, age matrix, address CAM

2.2. CHI SN-F Interface
   - No snoop channels (SN-F is non-coherent)
   - RXREQ: incoming read/write requests from HN-F
   - RXDAT: incoming write data from HN-F (CopyBackWrData)
   - TXRSP: outgoing completion responses (Comp, CompDBIDResp)
   - TXDAT: outgoing read data (CompData)
   - L-Credit flow control on each channel

2.3. AXI4 Master Interface
   - Read channel: AR (address) → R (data + response)
   - Write channel: AW (address) + W (data) → B (response)
   - Burst support: INCR bursts for cache line-sized transfers
   - Outstanding transaction support via AXI ID field

### 3. Transaction Flows

3.1. ReadNoSnp → AXI Read
   - HN-F sends ReadNoSnp on RXREQ (address, TxnID, size)
   - OpenNCB allocates transaction entry, issues AXI AR
   - Memory controller returns AXI R beats
   - OpenNCB assembles cache line, sends CompData on TXDAT
   - Transaction completes when HN-F sends CompAck (if required)
   - Sequence diagram: HN-F → SN-F → Memory → SN-F → HN-F

3.2. WriteNoSnp → AXI Write
   - HN-F sends WriteNoSnp on RXREQ (address, TxnID)
   - OpenNCB returns CompDBIDResp on TXRSP (allocates data buffer)
   - HN-F sends write data on RXDAT (CopyBackWrData)
   - OpenNCB issues AXI AW + W to memory controller
   - Memory controller returns AXI B (write response)
   - Sequence diagram: HN-F → SN-F → Memory

3.3. MMIO Transactions
   - Same ReadNoSnp/WriteNoSnp opcodes, but targeting device address space
   - MMIO bridge instances use smaller outstanding depth (32 vs. 64)
   - Ordering: device accesses may require strict ordering (no reordering)

### 4. NCB200 Internals

4.1. Transaction Queue
   - Fixed-depth queue of outstanding CHI transactions
   - Each entry tracks: TxnID, address, opcode, state, AXI ID mapping
   - Queue depth configurable (64 for LLC bridge, 32 for MMIO)

4.2. Payload Storage
   - Buffer for holding write data between CHI RXDAT and AXI W
   - Also buffers read data between AXI R and CHI TXDAT
   - Sized to support maximum outstanding transactions × cache line size

4.3. Age Matrix and Ordering
   - Tracks relative age of outstanding transactions
   - Ensures AXI ordering requirements are met
   - Older transactions have priority in arbitration

4.4. Address CAM (Content-Addressable Memory)
   - Detects address conflicts between outstanding transactions
   - Same-address transactions must be serialized to prevent ordering violations
   - CAM lookup on every new request

### 5. Data Path Details

5.1. CHI-to-AXI Data Width Adaptation
   - CHI DAT channel: 256-bit (32-byte) data flit
   - AXI data width: configurable (typically 256-bit or 128-bit)
   - Width conversion logic for mismatched configurations

5.2. Data Parity and Error Checking
   - Odd-parity data check on CHI data flits (configurable)
   - Error propagation: CHI data error → AXI RRESP/BRESP error signaling

5.3. Byte Enable Handling
   - CHI BE (byte enable) field for partial writes
   - Mapping to AXI WSTRB (write strobe)

### 6. Credit and Flow Control

6.1. CHI L-Credit Management
   - OpenNCB manages credits for TXRSP and TXDAT channels
   - RXREQ and RXDAT credits returned as buffer space frees
   - Credit depth tied to transaction queue depth

6.2. AXI Back-Pressure
   - AXI ready/valid handshake on each channel
   - When memory controller is slow: AXI ready deasserted → OpenNCB stalls
   - Stall propagation: AXI stall → CHI credit exhaustion → HN-F back-pressure

### 7. Worked Example: Cache Miss to Memory and Back

7.1. Scenario
   - Core 0 loads from address X — misses L1, L2, and L3
   - OpenLLC issues ReadNoSnp to OpenNCB → memory read → data return

7.2. End-to-End Trace
   - Table: cycle | module | interface | signal/channel | description
   - Core 0 → L1 miss → L2 (CoupledL2 TXREQ ReadUnique) → OpenLLC directory miss
   - OpenLLC MemUnit → TXREQ ReadNoSnp to SN-F → OpenNCB
   - OpenNCB → AXI AR → memory controller → AXI R data
   - OpenNCB → TXDAT CompData → OpenLLC RefillUnit
   - OpenLLC → CompData to CoupledL2 → L2 → L1 → core writeback

7.3. Latency Breakdown
   - Approximate cycle counts per hop (L2 → LLC → NCB → memory → back)
   - Where the time is spent: memory access dominates, but bridge overhead matters

### 8. MMIO Bridge Details

8.1. Per-Core MMIO Architecture
   - Each core has its own MMIO OpenNCB instance
   - MMIO traffic bypasses the L3 entirely (MMIODiverger in OpenLLC)
   - Direct path: CoupledL2 MMIO → OpenLLC MMIO diverge → MMIO OpenNCB → AXI4

8.2. Device Access Ordering
   - MMIO accesses are strictly ordered (no reordering allowed)
   - OpenNCB MMIO instances enforce in-order completion
   - Contrast with LLC bridge which may reorder for performance

### 9. Design Trade-Offs

9.1. Outstanding Depth: Throughput vs. Area
   - More outstanding transactions → better memory-level parallelism
   - Each entry costs: transaction state, payload buffer, CAM entry
   - 64 entries for LLC bridge is generous; some designs use 16-32

9.2. Single vs. Multiple Memory Ports
   - Current: all 4 LLC slices share one SN-F → one AXI4 port
   - Bottleneck: aggregate LLC miss rate × line size must fit in AXI bandwidth
   - Alternative: multiple SN-F nodes with address interleaving

9.3. Bridge Complexity vs. Native AXI in LLC
   - OpenNCB adds translation latency (CHI → AXI)
   - Alternative: LLC issues AXI directly, bypassing CHI for memory-side
   - Trade-off: protocol purity and modularity vs. latency

9.4. Parity vs. ECC for Data Integrity
   - OpenNCB uses odd parity (1 bit per byte) — detects single-bit errors
   - ECC would correct errors but costs more area and latency
   - Appropriate for simulation; production may need stronger protection

### 10. Common Misconceptions

- **"SN-F participates in coherence."** SN-F is explicitly non-coherent. It never
  receives snoops and never tracks cache state. All coherence is resolved at the
  HN-F (OpenLLC) before requests reach SN-F.

- **"One OpenNCB handles all traffic."** There are actually N+1 OpenNCB instances
  in a CHI config: one for LLC-to-memory and one MMIO bridge per core. They are
  independent and can process transactions concurrently.

### 11. Key Takeaways

1. OpenNCB (SN-F) is the CHI-to-AXI4 bridge — the boundary between the
   coherent fabric and the non-coherent memory system.
2. It handles only ReadNoSnp and WriteNoSnp — all coherence has already been
   resolved by the time requests arrive at SN-F.
3. The NCB200 core provides transaction queuing, payload buffering, ordering
   enforcement (age matrix + address CAM), and AXI burst generation.
4. Separate MMIO OpenNCB instances (one per core) handle device access with
   strict ordering guarantees.
5. Outstanding transaction depth (64 for LLC, 32 for MMIO) determines the
   degree of memory-level parallelism available to the system.

### 12. Checkpoint Questions

**Basic:**
1. What CHI opcodes does OpenNCB (SN-F) receive, and why are there no snoop
   channels?
2. How does OpenNCB signal that it is ready to receive write data from the HN-F?
3. Why does XiangShan instantiate multiple OpenNCB instances instead of routing
   all traffic through one?

**Intermediate:**
4. Trace a WriteNoSnp through OpenNCB, identifying the CHI and AXI messages
   at each stage. At what point is the write considered "committed"?
5. Two ReadNoSnp requests arrive at OpenNCB targeting the same address.
   How does the address CAM handle this? What ordering guarantee must be preserved?

**Advanced:**
6. OpenNCB's LLC bridge has 64 outstanding entries. For a memory with 100ns
   access latency and a 2GHz core clock (200 cycles), calculate the maximum
   sustainable read bandwidth assuming 64-byte cache lines. Is 64 entries
   sufficient to saturate a DDR5-4800 channel?
7. Design a dual-SN-F configuration where memory addresses are interleaved
   across two OpenNCB instances. What changes are needed in OpenLLC's SNXbar?
   What is the expected bandwidth improvement?
8. Compare OpenNCB's age-matrix ordering approach to a simple FIFO. Under what
   traffic patterns does the age matrix provide better throughput?

### 13. Further Reading

1. OpenNCB source: `openLLC/openNCB/src/main/scala/openncb/`
2. CHI SN-F interface: `openLLC/openNCB/src/main/scala/openncb/chi/intf/`
3. Chapter 29 of this book — OpenLLC (the HN-F upstream of OpenNCB)
4. ARM AMBA CHI Architecture Specification — Slave Node transaction rules
5. ARM AMBA AXI Protocol Specification — AXI4 channel definitions
