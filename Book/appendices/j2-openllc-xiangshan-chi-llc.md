# J.2 OpenLLC: XiangShan's CHI-Based Last-Level Cache

<!-- Status: Table of contents only — content to be written -->

---

## Table of Contents

1. **Introduction and Design Context**
   1.1. Why a CHI-Native L3? Motivation for Replacing HuanCun
   1.2. OpenLLC in the XiangShan SoC: CHIConfig vs. TLConfig
   1.3. Configuration and Instantiation (`OpenLLCParam`, `EnableCHI`)

2. **Architecture Overview**
   2.1. Top-Level Block Diagram
   2.2. Banked Slice Architecture (RNXbar → Slices → SNXbar)
   2.3. MMIO Path: MMIODiverger and MMIOMerger
   2.4. Inclusion Policy: Exclusive (1 RN) vs. Non-Inclusive (Multi-RN)

3. **CHI Subset Implemented**
   3.1. Supported Request Opcodes (11 of 50+)
   3.2. Supported Snoop Opcodes (5 of 15+)
   3.3. Supported Response and Data Opcodes
   3.4. What Is Not Supported: Atomics, DVM, Stash, CMO, Forwarding
   3.5. Why This Subset Is Sufficient for XiangShan

4. **Crossbar and Routing**
   4.1. RNXbar: Address-Based Bank Routing
   4.2. SNXbar: TxnID-Based Demultiplexing
   4.3. Snoop Broadcast with Mask Filtering
   4.4. Scalability Limits of the Crossbar Topology

5. **Slice Internals**
   5.1. Slice Block Diagram
   5.2. RequestBuffer and RequestArb
   5.3. MainPipe: 6-Stage Pipeline (S2–S6)
   5.4. Directory: Tag Array and Snoop Filter
   5.5. DataStorage: SRAM Data Array
   5.6. Coherence State Tracking (I, SC, UC, UD_PD, SD)

6. **Transaction Processing Walkthrough**
   6.1. ReadUnique: L2 Miss → Snoop → Memory Fetch → CompData
   6.2. WriteBackFull: L2 Eviction → Directory Update → Memory Write
   6.3. MakeUnique: Permission Upgrade → Snoop Invalidation → Comp
   6.4. Evict: Silent Eviction → Directory Deallocation

7. **Functional Units**
   7.1. RefillUnit: Pending Memory Read Completions
   7.2. MemUnit: ReadNoSnp/WriteNoSnp to Downstream SN
   7.3. ResponseUnit: Comp/CompDBIDResp Scheduling
   7.4. SnoopUnit: TXSNP Generation and Tracking

8. **CHI Link Layer**
   8.1. RNLinkMonitor and SNLinkMonitor
   8.2. Credit-Based Flow Control Implementation
   8.3. Link State Machine in OpenLLC

9. **OpenNCB: CHI-to-AXI4 Bridge**
   9.1. NCB-200 Architecture and Role
   9.2. Transaction Queue and Payload Storage
   9.3. CHI ReadNoSnp → AXI AR+R Flow
   9.4. CHI WriteNoSnp → AXI AW+W+B Flow
   9.5. Ordering Enforcement (Age Matrix, Address CAM)
   9.6. Configuration Parameters

10. **Performance Monitoring**
    10.1. TopDownMonitor and L3 Miss Reporting
    10.2. CHI Logger Integration
    10.3. Performance Counters

11. **OpenLLC vs. HuanCun Comparison**
    11.1. Protocol Differences (CHI vs. TileLink)
    11.2. Inclusion Model Differences
    11.3. Memory Interface Differences
    11.4. Configuration Switch: `L3CacheParamsOpt` vs. `OpenLLCParamsOpt`

12. **Worked Example**
    12.1. Multi-Core ReadUnique with Snoop: Cycle-by-Cycle Trace

13. **Design Trade-Offs**
    13.1. Subset CHI vs. Full Protocol: Complexity Savings
    13.2. Crossbar vs. Ring: Latency vs. Scalability
    13.3. Non-Inclusive vs. Inclusive L3: Area and Traffic Trade-Offs

14. **Key Takeaways**

15. **Checkpoint Questions**

16. **Further Reading**
    - OpenLLC source: `openLLC/src/main/scala/openLLC/`
    - OpenNCB source: `openLLC/openNCB/src/main/scala/openncb/`
    - Appendix J.1 (CHI Protocol Fundamentals)
    - Chapter 26 (L2 Cache / CoupledL2)
    - Chapter 27 (L3 Cache / HuanCun / OpenLLC)
