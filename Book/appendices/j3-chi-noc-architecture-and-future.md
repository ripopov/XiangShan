# J.3 Toward a Full CHI NoC: Architecture and Future Directions

<!-- Status: Table of contents only — content to be written -->

---

## Table of Contents

1. **Introduction**
   1.1. From Crossbar to Network-on-Chip: Why Topology Matters
   1.2. Limitations of OpenLLC's Star Topology
   1.3. Industry Context: ARM CMN, CXL, and Multi-Die Coherence

2. **CHI Network Layer**
   2.1. Protocol / Network / Link Layer Separation
   2.2. Network Topology Options: Ring, Mesh, Torus, Hierarchical
   2.3. Node ID Assignment and SAM Configuration
   2.4. Routing Algorithms: Deterministic, Adaptive, Source-Based

3. **Completing the CHI Protocol**
   3.1. Atomic Operations: Requirements and Home Node Support
   3.2. DVM Operations: TLB Shootdown Across a NoC
   3.3. Stash Transactions: Prefetch Hints to Specific Nodes
   3.4. Snoop Forwarding (SnpXFwd): Direct Cache-to-Cache Transfer
   3.5. Cache Maintenance Operations for Software-Managed Coherence
   3.6. Exclusive Access and Lock Transactions

4. **Scaling the Coherence Directory**
   4.1. Snoop Filter vs. Full Directory at Scale
   4.2. Directory Sharding and Distributed Home Nodes
   4.3. Reducing Snoop Traffic: Precise vs. Coarse Tracking
   4.4. Back-Invalidation Policies for Directory Overflow

5. **Ring Interconnect Design**
   5.1. Unidirectional vs. Bidirectional Ring
   5.2. Ring Stop Architecture and Arbitration
   5.3. Bandwidth and Latency Analysis
   5.4. Ring Sizing: When Ring Becomes the Bottleneck

6. **Mesh Interconnect Design**
   6.1. 2D Mesh Topology for Many-Core
   6.2. Router Microarchitecture: Crossbar, Buffers, and Credit Flow
   6.3. Deadlock Avoidance: Virtual Channels and Routing Restrictions
   6.4. XY Routing and Adaptive Alternatives

7. **Multi-Die and Chiplet Coherence**
   7.1. Die-to-Die Interfaces: UCIe, BoW, Custom PHY
   7.2. CHI over Chiplet Links: Latency and Bandwidth Constraints
   7.3. Cross-Die Snoop Filtering and Home Node Placement
   7.4. NUMA-Aware Coherence and Data Placement

8. **CXL and Heterogeneous Coherence**
   8.1. CXL.cache and CXL.mem Protocol Overview
   8.2. CHI-to-CXL Bridging Considerations
   8.3. Coherent Accelerator Attachment via CXL Type 2

9. **Quality of Service and Partitioning**
   9.1. MPAM: Memory Performance and Monitoring
   9.2. QoS-Aware Arbitration in the Interconnect
   9.3. Bandwidth Partitioning and Isolation

10. **Verification and Validation**
    10.1. Protocol Compliance Checking
    10.2. Interconnect Functional Verification Strategies
    10.3. Performance Modeling and Simulation Frameworks

11. **Case Study: Hypothetical XiangShan CHI NoC**
    11.1. Target: 4–16 Core Ring with Distributed Home Nodes
    11.2. Migration Path from OpenLLC Crossbar
    11.3. Required RTL Changes: CoupledL2, LLC, and Interconnect
    11.4. Expected Performance Trade-Offs

12. **Design Trade-Offs**
    12.1. Crossbar vs. Ring vs. Mesh: Area, Latency, Bandwidth
    12.2. Protocol Completeness vs. Verification Complexity
    12.3. Directory Size vs. Snoop Traffic
    12.4. Single-Die vs. Multi-Die Partitioning Decisions

13. **Key Takeaways**

14. **Checkpoint Questions**

15. **Further Reading**
    - ARM AMBA CHI Architecture Specification
    - ARM CoreLink CMN-700 Technical Reference Manual
    - CXL Specification (Compute Express Link)
    - Appendix J.1 (CHI Protocol Fundamentals)
    - Appendix J.2 (OpenLLC Implementation)
