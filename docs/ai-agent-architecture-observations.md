[English](ai-agent-architecture-observations.md) | [中文版](ai-agent-architecture-observations.zh-TW.md)

# AI Agent Architecture Observations

## About This Document

This document is a human-led deep research note. AI is used only as a research accelerator and collaborator for literature exploration, counter-argument generation, and structural organization. All conclusions, architectural judgments, and trade-offs are made by the author. This document is an engineering research note, not an academic proof.

This document summarizes **personal development observations** about adopting an ECS-inspired system-based architecture in AI-assisted development. The content **is not a rigorous research conclusion**, and is presented only as tendencies or hypotheses.

## Encapsulation and Boundaries (Observations, Not Conclusions)

Encapsulation and access control provide correctness boundaries that are valuable to both humans and AI. This project also uses architectural boundaries such as handlers, request-scoped contexts, and actor serialization to reduce misuse risks, but this **does not** mean encapsulation is unnecessary. When needed, constraints should still be strengthened through types and access control.

## Related Research (Background)

**1. Statistical Patterns vs Logical Reasoning**

- **"A Peek into Token Bias: Large Language Models Are Not Yet Genuine Reasoners"** (Jiang et al., 2024)
  - Argues that LLM "reasoning" may be influenced by token bias and surface patterns
  - https://arxiv.org/abs/2406.11050

- **"LLMs and the Logical Space of Reasons"** (Minds & Machines, 2025)
  - Discusses the relationship between LLMs and the norms of human logical reasoning
  - https://link.springer.com/article/10.1007/s11023-025-09751-y

**2. LLM Understanding of Design Patterns**

- **"Do Code LLMs Understand Design Patterns?"** (2025)
  - Reports that LLM understanding and consistency of design patterns still fluctuates, with observable limitations
  - https://arxiv.org/abs/2501.04835

**3. Reasoning Patterns in Code Generation**

- **"A Study on Thinking Patterns of Large Reasoning Models in Code Generation"** (Halim et al., 2025)
  - Builds a taxonomy of reasoning actions and discusses the relationship between reasoning style and correctness
  - https://arxiv.org/abs/2509.13758

**4. Cognitive Load and Code Readability**

- **"Measuring the cognitive load of software developers"** (2021)
  - Explores how code complexity, language familiarity, and presentation affect cognitive load
  - https://www.sciencedirect.com/science/article/abs/pii/S095058492100046X

- **"LLM-Based Test-Driven Interactive Code Generation"** (2024)
  - Reports that test-driven AI code generation workflows may reduce cognitive load
  - https://arxiv.org/abs/2404.10100

## Research Gaps

Currently, **no papers directly study** the following topics:

- Differences in cognitive load for humans vs AI when using pure function decomposition in AI-assisted development
- The impact of statistical pattern learning on human cognitive load in code comprehension
- The impact of AI-optimized code design (e.g., ECS-inspired system-based architecture) on human readability

## Our Observations (Bias-Aware Description)

Based on practical development experience:

- AI may **align** with architectural constraints through statistical pattern learning
- Function signatures and code patterns **may** help alignment, but encapsulation/tests are still needed as defenses
- This design **may** be more efficient in AI-assisted development contexts

The above are **observations** only and have not been validated by rigorous academic research.

## Why Validation Is Difficult

In theory, these could be validated with comparative experiments, such as:

- Using the same LLM model
- Comparing systems (ECS-inspired) with traditional OOP design
- Comparing development efficiency (code generation speed, correctness rate, modification count, etc.)

In practice, there are many difficult-to-control variables:

- **Prompt differences**: prompts across design patterns are hard to make fully equivalent
- **Task complexity**: different tasks adapt differently to each design pattern
- **Model versions**: performance varies widely across model versions
- **Developer experience**: human familiarity with each pattern differs
- **Codebase context**: existing code style influences AI output
- **Test criteria**: how to objectively measure "development efficiency" and "code quality"

Therefore, these observations are currently **hard to validate through rigorous experiments**, and are more a summary of subjective impressions from real-world development experience.
