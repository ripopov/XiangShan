# Appendix I. TileLink Protocol (Multi-Document)

This appendix provides a comprehensive treatment of the TileLink protocol as used in
XiangShan Kunminghu. It is organized as three self-contained documents that build on each
other progressively.

---

## I. Reading Order

1. [I.1 Cache Coherence Fundamentals](i1-cache-coherence-fundamentals.md)
   Focus: Cache coherence problem, protocols, and foundational concepts.
   Outcome: Understand why coherence is necessary, how snooping and directory protocols
   work, and how MOESI/MESI state machines maintain consistency.

2. [I.2 TileLink Protocol Specification](i2-tilelink-protocol-specification.md)
   Focus: TileLink bus protocol — channels, messages, conformance levels, and ordering rules.
   Outcome: Read and reason about TileLink transactions at the channel/beat level.

3. [I.3 TileLink in XiangShan: DCache and L2 Implementation](i3-tilelink-xiangshan-implementation.md)
   Focus: How XiangShan's DCache and CoupledL2 implement TileLink coherence.
   Outcome: Trace a coherence transaction from L1 miss through L2 response in RTL.

---

## I. Motivation

Chapter 28 of the main text covers TileLink and CHI at the architectural level. This
appendix series serves as a standalone reference that can be read independently of the main
chapters, providing both the theoretical grounding (I.1), the protocol specification (I.2),
and the concrete XiangShan implementation details (I.3).
