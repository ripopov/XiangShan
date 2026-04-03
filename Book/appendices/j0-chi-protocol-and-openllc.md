# Appendix J. CHI Protocol and OpenLLC (Multi-Document)

This appendix provides a comprehensive treatment of the AMBA CHI (Coherent Hub Interface)
protocol and its implementation in XiangShan Kunminghu's CHI-based cache hierarchy. It is
organized as three self-contained documents that build on each other progressively.

---

## J. Reading Order

1. [J.1 CHI Protocol Fundamentals](j1-chi-protocol-fundamentals.md)
   Focus: CHI architecture, node types, channels, flit formats, coherence model, and
   transaction flows.
   Outcome: Understand CHI's layered architecture, how Home/Request/Slave nodes interact,
   and how CHI transactions maintain coherence.

2. [J.2 OpenLLC: XiangShan's CHI-Based Last-Level Cache](j2-openllc-xiangshan-chi-llc.md)
   Focus: OpenLLC architecture, supported CHI subset, internal pipeline, snoop filter,
   and OpenNCB bridge.
   Outcome: Trace a coherence transaction from L2 through OpenLLC to memory, understand
   the banked slice design, and identify the CHI subset that XiangShan implements.

3. [J.3 Toward a Full CHI NoC: Architecture and Future Directions](j3-chi-noc-architecture-and-future.md)
   Focus: Scaling beyond the OpenLLC crossbar to a full CHI network-on-chip, covering
   ring/mesh topologies, protocol completeness, and multi-die considerations.
   Outcome: Understand what a production CHI interconnect requires beyond OpenLLC, and
   the architectural trade-offs in scaling XiangShan's coherence fabric.

---

## J. Motivation

Part V of the main text (Chapters 26–30) covers directory-based coherence, AMBA CHI, and
each CHI node in XiangShan. Appendix I covers TileLink in depth. When `EnableCHI` is set,
XiangShan replaces the TileLink-based HuanCun L3 with OpenLLC, a CHI-native last-level
cache. This appendix series provides supplementary protocol detail (J.1), implementation
deep-dives (J.2), and forward-looking architectural context for full CHI NoC designs (J.3).

---

## J. Prerequisites

- Appendix I.1 (Cache Coherence Fundamentals) — MESI/MOESI state machines
- Chapter 27 (AMBA CHI in XiangShan) — protocol overview, node types, channels
- Chapter 28 (CoupledL2 — RN-F) — understanding of the L2 as a CHI Request Node
