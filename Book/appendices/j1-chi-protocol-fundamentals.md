# J.1 CHI Protocol Fundamentals

<!-- Status: Table of contents only — content to be written -->

---

## Table of Contents

1. **Introduction and Motivation**
   1.1. Why CHI? From AXI/ACE to a Scalable Coherence Fabric
   1.2. CHI in the AMBA Family: Positioning and History
   1.3. CHI Issue Versions (B, C, E.b) and Feature Evolution

2. **CHI Architecture Overview**
   2.1. Layered Protocol Model (Protocol / Network / Link)
   2.2. Node Types: RN-F, RN-I, RN-D, HN-F, HN-I, SN-F, SN-I, MN
   2.3. System Address Map (SAM) and Target ID Routing
   2.4. Point-of-Coherence (PoC) and Point-of-Serialization (PoS)

3. **Channels and Flit Format**
   3.1. Channel Overview: REQ, RSP, SNP, DAT
   3.2. Flit Structure and Field Encoding
   3.3. TxnID, DBID, and Transaction Tracking
   3.4. Credit-Based Flow Control (L-Credits)

4. **Coherence Model**
   4.1. CHI Cache States: I, SC, UC, UD, SD and the Dirty Bit
   4.2. Permitted State Transitions
   4.3. Comparison with MOESI and TileLink States
   4.4. Snoop Filter vs. Full Directory

5. **Transaction Flows**
   5.1. Read Transactions (ReadShared, ReadUnique, ReadNotSharedDirty, ReadOnce)
   5.2. Dataless Transactions (MakeUnique, CleanInvalid, MakeInvalid, Evict)
   5.3. Write-Back Transactions (WriteBackFull, WriteCleanFull, WriteEvictFull)
   5.4. Snoop Transactions (SnpUnique, SnpShared, SnpCleanInvalid, SnpMakeInvalid)
   5.5. Snoop Forwarding (SnpXFwd) and Direct Data Transfer
   5.6. Non-Coherent Transactions (ReadNoSnp, WriteNoSnp)

6. **Ordering, Barriers, and Completion**
   6.1. CompAck and the Three-Message Handshake
   6.2. Request Order Field and Endpoint Ordering
   6.3. Barriers and Ordering Guarantees
   6.4. Retry and P-Credit Mechanism

7. **Advanced Features**
   7.1. Atomic Transactions (AtomicLoad, AtomicStore, AtomicSwap, AtomicCompare)
   7.2. DVM Operations (TLB Invalidation Broadcast)
   7.3. Stash Transactions (StashOnce, WriteUniqueStash)
   7.4. Cache Maintenance Operations (CleanSharedPersist, PrefetchTgt)
   7.5. MPAM (Memory Performance and Monitoring)
   7.6. Data Check, Poison, and RAS Features

8. **Link Layer**
   8.1. Link Activation State Machine (STOP, ACTIVATE, RUN, DEACTIVATE)
   8.2. Credit Management and Back-Pressure
   8.3. Async Bridge Considerations

9. **CHI vs. TileLink Comparison**
   9.1. Protocol Philosophy: Channel-Based vs. Transaction-Based
   9.2. Scalability: Point-to-Point vs. Shared Bus
   9.3. Feature Richness: What CHI Adds Over TileLink
   9.4. When to Use Each in XiangShan Configurations

10. **Key Takeaways**

11. **Checkpoint Questions**

12. **Further Reading**
    - ARM AMBA CHI Architecture Specification (Issue E.b)
    - ARM AMBA CHI Protocol Summary (Issue B)
    - Appendix I.1 (Cache Coherence Fundamentals)
