# XiangShan Kunminghu Microarchitecture Book

This book is organized in Markdown and follows the full chapter plan in `AGENTS.md`.

## Table of Contents

### Part I — Overview and Fundamentals

1. [Introduction](part-01-overview-and-fundamentals/01-introduction.md) `DONE`
2. [Architecture at a Glance](part-01-overview-and-fundamentals/02-architecture-at-a-glance.md) `DONE`
3. [SoC Integration](part-01-overview-and-fundamentals/03-soc-integration.md) `DONE`

### Part II — Frontend (Instruction Supply)

4. [Frontend Overview](part-02-frontend-instruction-supply/04-frontend-overview.md) `EMPTY`
5. [Branch Prediction Unit (BPU)](part-02-frontend-instruction-supply/05-branch-prediction-unit.md) `DONE`
   - 5a. [BPU Top-Level Architecture](part-02-frontend-instruction-supply/05a-bpu-top-level-architecture.md) `DONE`
   - 5b. [Fast Predictors (s1 Layer)](part-02-frontend-instruction-supply/05b-fast-predictors.md) `DONE`
   - 5c. [Accurate Predictors (s2/s3 Layer)](part-02-frontend-instruction-supply/05c-accurate-predictors.md) `DONE`
   - 5d. [History, Training, and Recovery](part-02-frontend-instruction-supply/05d-history-training-recovery.md) `DONE`
6. [Fetch Target Queue (FTQ)](part-02-frontend-instruction-supply/06-fetch-target-queue.md) `DONE`
   - 6a. [FTQ Implementation](part-02-frontend-instruction-supply/06a-ftq-implementation.md) `DONE`
7. [Instruction Cache (ICache)](part-02-frontend-instruction-supply/07-instruction-cache.md) `EMPTY`
8. [Instruction Fetch Unit (IFU)](part-02-frontend-instruction-supply/08-instruction-fetch-unit.md) `EMPTY`
9. [Instruction Buffer (IBuffer)](part-02-frontend-instruction-supply/09-instruction-buffer.md) `EMPTY`

### Part III — Backend (Execution Engine)

10. [Backend Overview](part-03-backend-execution-engine/10-backend-overview.md) `EMPTY`
11. [Decode Stage](part-03-backend-execution-engine/11-decode-stage.md) `EMPTY`
12. [Rename Stage](part-03-backend-execution-engine/12-rename-stage.md) `EMPTY`
13. [Dispatch](part-03-backend-execution-engine/13-dispatch.md) `EMPTY`
14. [Issue Queues and Scheduling](part-03-backend-execution-engine/14-issue-queues-and-scheduling.md) `EMPTY`
15. [Physical Register File](part-03-backend-execution-engine/15-physical-register-file.md) `EMPTY`
16. [Functional Units](part-03-backend-execution-engine/16-functional-units.md) `EMPTY`
17. [Reorder Buffer (ROB)](part-03-backend-execution-engine/17-reorder-buffer.md) `EMPTY`
18. [Data Path and Writeback](part-03-backend-execution-engine/18-data-path-and-writeback.md) `EMPTY`

### Part IV — Memory Subsystem

19. [Memory Subsystem Overview](part-04-memory-subsystem/19-memory-subsystem-overview.md) `EMPTY`
20. [Load Pipeline](part-04-memory-subsystem/20-load-pipeline.md) `EMPTY`
21. [Store Pipeline](part-04-memory-subsystem/21-store-pipeline.md) `EMPTY`
22. [Load Queue and Store Queue](part-04-memory-subsystem/22-load-queue-and-store-queue.md) `EMPTY`
23. [L1 Data Cache (DCacheWrapper)](part-04-memory-subsystem/23-l1-data-cache.md) `EMPTY`
24. [Hardware Prefetching](part-04-memory-subsystem/24-hardware-prefetching.md) `EMPTY`
25. [Memory Management Unit (MMU)](part-04-memory-subsystem/25-memory-management-unit.md) `EMPTY`

### Part V — Cache Hierarchy and Interconnect

26. [L2 Cache (CoupledL2)](part-05-cache-hierarchy-and-interconnect/26-l2-cache-coupledl2.md) `EMPTY`
27. [L3 Cache / LLC (HuanCun / OpenLLC)](part-05-cache-hierarchy-and-interconnect/27-l3-cache-llc.md) `EMPTY`
28. [Coherence Protocol](part-05-cache-hierarchy-and-interconnect/28-coherence-protocol.md) `EMPTY`

### Part VI — Privileged Architecture and Debug

29. [Privilege Modes and Trap Handling](part-06-privileged-architecture-and-debug/29-privilege-modes-and-trap-handling.md) `EMPTY`
30. [Performance Counters and Events](part-06-privileged-architecture-and-debug/30-performance-counters-and-events.md) `EMPTY`
31. [Debug and Trace](part-06-privileged-architecture-and-debug/31-debug-and-trace.md) `EMPTY`

### Part VII — Physical Design Considerations

32. [Clock, Reset, and Power Management](part-07-physical-design-considerations/32-clock-reset-and-power-management.md) `EMPTY`
33. [Design for Testability](part-07-physical-design-considerations/33-design-for-testability.md) `EMPTY`

### Appendices

A. [Full Parameter Table](appendices/a-full-parameter-table.md) `EMPTY`
B. [Signal/Bundle Glossary](appendices/b-signal-bundle-glossary.md) `EMPTY`
C. [Functional Unit Configuration Table](appendices/c-functional-unit-configuration-table.md) `EMPTY`
D. [CSR Register Map](appendices/d-csr-register-map.md) `EMPTY`
E. [Build and Simulation Guide](appendices/e-build-and-simulation-guide.md) `EMPTY`
F. [Glossary of Acronyms and Terms](appendices/f-glossary.md) `EMPTY`
G. [Scala and Chisel Introduction (Overview)](appendices/g0-scala-and-chisel-introduction.md) `DONE`
G.1 [Scala Primer (Java/SV Readers)](appendices/g1-scala-primer-for-java-and-systemverilog-readers.md) `DONE`
G.2 [Chisel Primer (SV Readers)](appendices/g2-chisel-primer-for-systemverilog-readers.md) `DONE`
G.3 [XiangShan Scala/Chisel Reading Playbook](appendices/g3-xiangshan-scala-chisel-code-reading-playbook.md) `DONE`
H. [AMBA CHI Protocol: Ground-Up Conceptual Introduction](appendices/h-amba-chi-protocol-introduction.md) `DONE`
I. [TileLink Protocol (Overview)](appendices/i0-tilelink-protocol-overview.md) `PLAN`
  I.1 [Cache Coherence Fundamentals](appendices/i1-cache-coherence-fundamentals.md) `PLAN`
  I.2 [TileLink Protocol Specification](appendices/i2-tilelink-protocol-specification.md) `PLAN`
  I.3 [TileLink in XiangShan: DCache and L2 Implementation](appendices/i3-tilelink-xiangshan-implementation.md) `PLAN`

## Status

- Fully written: Chapters 1, 2, and 3 (`Part I` complete)
- Fully written: Chapter 5 + companion chapters 5a–5d (Branch Prediction Unit)
- Fully written: Chapter 6 + companion chapter 6a (Fetch Target Queue)
- Fully written appendices: Appendix G (multi-document Scala/Chisel introduction)
- Placeholder-only: all remaining chapters and appendices except those listed above
