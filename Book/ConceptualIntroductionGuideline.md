# Conceptual Introduction Chapter Guidelines

The conceptual chapter should be **self-contained for understanding**. A reader who reads only the
intro chapter should be able to explain the unit's purpose, mechanisms, and trade-offs to a
colleague. The implementation chapters add *how Kunminghu does it specifically*, grounded in RTL,
but the conceptual chapter should never require RTL knowledge to follow.

## Structure and Pedagogy

1. **Problem first.** Open with what goes wrong *without* the mechanism. Use quantitative pain
   (IPC loss, stall cycles, energy waste) before introducing any solution. The reader must *feel*
   the problem before they will care about the solution.

2. **"Design it yourself" progression.** After stating the problem, pose it as a challenge:
   *"Given these constraints, how would you solve this?"* Walk the reader through a naive
   attempt, expose its failure with a concrete scenario, then iterate toward the real design.
   This Socratic scaffolding builds intuition that no amount of description can match.

3. **Analogy anchor.** Provide one real-world analogy per major mechanism — not as decoration,
   but as a reasoning tool the reader can fall back on when the details get dense. Good analogies
   are *structurally faithful*: they preserve the key relationships (e.g., branch prediction as
   a highway exit decision made before the sign is readable). Bad analogies just share surface
   similarity. State explicitly where the analogy breaks down.

4. **ASCII mental model up front.** Side-by-side "without vs. with" diagram on the first page,
   captioned "Read This First," followed by a bold one-sentence takeaway.

5. **Terminology table at point of need.** Define terms in the section where they first appear,
   not at the top or bottom. Keep to 1–2 sentences each.

6. **Incremental complexity.** Present 2–3 levels of sophistication (simple → real design). Each
   transition motivated by a concrete failure of the previous level, with a quantitative
   comparison. Frame each level as: *What breaks? → Why? → What do we add?*

7. **Worked examples with concrete numbers.** At least one cycle-by-cycle or step-by-step trace
   showing state changes (not just equations). Use small, traceable values (e.g., 4-entry queue,
   8-cycle window) so the reader can verify each step by hand.

8. **Four diagram types.** Block diagram, state/FSM, data-flow/pipeline, and process flowchart.
   Every non-trivial mechanism gets a visual. ASCII for mental models, Mermaid for flows.

9. **Light forward references.** One sentence per section pointing to the implementation chapter.
   Never preview implementation details — no dependency on companion chapters.

10. **Minimal code citations.** At most 3–5 in the whole chapter, only to anchor key algorithms.
    Save code walkthroughs for companion chapters.

## Depth and Perspective

11. **Myth-busting callouts.** Identify 1–3 common misconceptions about the mechanism and refute
    them explicitly in a "Common Misconception" box. Students arrive with mental models from
    textbook simplifications or internet folklore — name the wrong model, explain why it's wrong,
    and replace it.

12. **Pathological cases.** For every mechanism, describe at least one adversarial or worst-case
    scenario. What input pattern defeats the design? How badly does performance degrade? This
    teaches the reader to think like a *designer*, not just a *describer*.

13. **Performance cliff visualization.** Where applicable, show how performance degrades
    non-linearly (e.g., cache thrashing beyond associativity, branch mispredict recovery cost
    scaling with pipeline depth). A simple graph or ASCII plot of "parameter vs. throughput"
    builds intuition about sensitivity that prose alone cannot.

14. **Instruction life story.** At least once per chapter, follow a single instruction (or a
    small sequence) through the unit end-to-end. Name concrete signals and queues even if
    abstractly — the reader should see the *journey*, not just the *architecture*.

15. **Industry comparison sidebar.** Briefly note how 1–2 other designs (e.g., ARM Cortex,
    Intel Core, BOOM) solve the same problem differently. This prevents the reader from assuming
    Kunminghu's approach is the only one, and sharpens understanding of *why* different choices
    suit different goals.

16. **Design trade-offs section.** Frame 2–4 dimensions as spectrums with pros/cons. Present the
    general trade-off, not Kunminghu's specific choice. Include area and energy alongside
    performance — modern design is a three-way negotiation, not a single-axis optimization.

17. **Context linkage.** A "broader pipeline context" section mapping interfaces to adjacent
    chapters. Show the unit as one node in a dependency graph: what does it consume, what does
    it produce, and what stalls when it stalls?
