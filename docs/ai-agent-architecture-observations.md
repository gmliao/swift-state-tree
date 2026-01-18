[English](ai-agent-architecture-observations.md) | [中文版](ai-agent-architecture-observations.zh-TW.md)

# AI Agent Architecture Observations

This document collects **personal observations** about using ECS-inspired system-based architecture in AI-assisted workflows. It is **not** a formal research conclusion; statements are framed as tendencies or hypotheses.

## Encapsulation and Boundaries (Observation, Not a Conclusion)

Encapsulation and access control define correctness boundaries and remain valuable for both humans and AI. In this project, we also rely on architectural boundaries (handler, request-scoped context, actor serialization) to reduce misuse risk, but that does **not** mean encapsulation is unnecessary. When needed, types and access control should still be used to strengthen constraints.

## Related Research (for context)

**1. Statistical patterning vs. logical reasoning**

- **"A Peek into Token Bias: Large Language Models Are Not Yet Genuine Reasoners"** (Jiang et al., 2024)
  - Suggests LLM "reasoning" can be influenced by token bias and surface patterns.
  - https://arxiv.org/abs/2406.11050

- **"LLMs and the Logical Space of Reasons"** (Minds & Machines, 2025)
  - Discusses the relationship between LLM behavior and normative rules of reasoning.
  - https://link.springer.com/article/10.1007/s11023-025-09751-y

**2. LLMs and design patterns**

- **"Do Code LLMs Understand Design Patterns?"** (2025)
  - Reports variability in how LLMs identify and reproduce design patterns.
  - https://arxiv.org/abs/2501.04835

**3. Reasoning patterns in code generation**

- **"A Study on Thinking Patterns of Large Reasoning Models in Code Generation"** (Halim et al., 2025)
  - Proposes a taxonomy of reasoning actions and explores their correlation with correctness.
  - https://arxiv.org/abs/2509.13758

**4. Cognitive load and code readability**

- **"Measuring the cognitive load of software developers"** (2021)
  - Studies how code complexity, familiarity, and presentation affect cognitive load.
  - https://www.sciencedirect.com/science/article/abs/pii/S095058492100046X

- **"LLM-Based Test-Driven Interactive Code Generation"** (2024)
  - Reports that test-driven AI workflows may reduce cognitive load.
  - https://arxiv.org/abs/2404.10100

## Research Gaps

There is currently **no direct research** on the following topics:

- Cognitive load differences (human vs AI) under pure-function decomposition in AI-assisted development
- How statistical pattern learning affects human cognitive load during code comprehension
- Readability effects of AI-oriented architectural choices (e.g., ECS-inspired system-based architecture)

## Our Observations (Tendencies)

Based on development experience:

- AI may align to architectural constraints via statistical pattern learning
- Function signatures + consistent calling patterns can **help alignment**, but still require tests and guardrails
- This approach **may** be more efficient in AI-assisted workflows under certain conditions

These are **observations**, not validated research results.

## Why Validation Is Hard

A rigorous validation would require a controlled comparison, such as:

- Same LLM model
- Systems (ECS-inspired) vs traditional OOP designs
- Comparable tasks and evaluation metrics (speed, correctness, revisions)

In practice, too many variables are hard to control:

- Prompt equivalence across designs
- Task complexity and domain suitability
- Model version drift
- Developer familiarity with the paradigm
- Codebase context and existing style
- Objective measurement of "efficiency" and "quality"

For now, these points remain experiential and should be treated as hypotheses.
