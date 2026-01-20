# Agent Skills for Swift StateTree

This directory contains Agent Skills that help AI assistants work effectively with the Swift StateTree project. These skills follow the [Agent Skills open standard](https://agentskills.io) and are compatible with Antigravity IDE, Claude Code, Cursor, and other AI coding assistants.

## Available Skills

Skills are organized in subdirectories for better management:

### Superpowers Skills

Located in `Superpowers/` directory - Complete set of development workflow skills from the [Superpowers framework](https://github.com/obra/superpowers):

**Core Workflow:**
- **Superpowers/brainstorming** - Use before any creative work. Explores user intent, requirements, and design before implementation.
- **Superpowers/writing-plans** - Creates detailed implementation plans for multi-step tasks, assuming zero context.
- **Superpowers/test-driven-development** - Enforces RED-GREEN-REFACTOR cycle with Swift Testing framework.
- **Superpowers/systematic-debugging** - Root cause investigation process before proposing fixes.
- **Superpowers/using-git-worktrees** - Creates isolated development branches for parallel work.

**Execution & Collaboration:**
- **Superpowers/executing-plans** - Batch execution with checkpoints
- **Superpowers/subagent-driven-development** - Fast iteration with two-stage review
- **Superpowers/dispatching-parallel-agents** - Concurrent subagent workflows
- **Superpowers/requesting-code-review** - Pre-review checklist
- **Superpowers/receiving-code-review** - Responding to feedback
- **Superpowers/finishing-a-development-branch** - Merge/PR decision workflow

**Meta:**
- **Superpowers/using-superpowers** - Introduction to the skills system
- **Superpowers/writing-skills** - Create new skills following best practices
- **Superpowers/verification-before-completion** - Ensure it's actually fixed

All skills include their complete structure with references, examples, and scripts as provided by Superpowers.

### SpecKit Skills

Located in `SpecKit/` directory - Spec-Driven Development workflow from [GitHub Spec-Kit](https://github.com/github/spec-kit):

**Complete Workflow:**
- **SpecKit/constitution** - Establish project governing principles and development guidelines (first step)
- **SpecKit/specify** - Define functional requirements and user stories (focus on WHAT and WHY)
- **SpecKit/clarify** - Clarify underspecified areas in specifications (before planning)
- **SpecKit/plan** - Create technical implementation plans with chosen tech stack
- **SpecKit/tasks** - Generate actionable task lists organized by user story with dependencies
- **SpecKit/implement** - Execute all tasks to build feature according to plan

**Integration with Superpowers:**
- Can be used alongside Superpowers skills
- `SpecKit/plan` provides high-level architecture, `Superpowers/writing-plans` provides detailed steps
- `SpecKit/implement` executes automatically, `Superpowers/executing-plans` provides batch review

### SwiftStateTree Project-Specific Skills

Located in `SwiftStateTree/` directory - Project-specific workflows and guidelines:

**Testing & Development:**
- **SwiftStateTree/run-e2e-tests** - Execute E2E tests with automatic server management and encoding mode support
- **SwiftStateTree/swift-testing-guidelines** - Guidelines for writing tests using Swift Testing framework

**GitHub Workflow:**
- **SwiftStateTree/view-pr-comments** - View PR details, comments, and reviews using GitHub CLI
- **SwiftStateTree/reply-pr-comment** - Reply to specific PR comment threads

**Code Generation:**
- **SwiftStateTree/generate-schema** - Generate JSON schema from LandDefinitions and TypeScript client SDK

**Code Guidelines:**
- **SwiftStateTree/deterministic-math-guidelines** - Guidelines for using deterministic math in game logic (cross-platform compatibility)

### UI/UX Pro Max Skill

Located in `UI-UX-Pro-Max/` directory - Design intelligence skill from [UI-UX-Pro-Max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill):

- **UI-UX-Pro-Max/ui-ux-pro-max** - Comprehensive UI/UX design intelligence with 57 styles, 95 color palettes, 56 font pairings, 24 chart types, and support for 11 tech stacks (React, Next.js, Vue, SwiftUI, React Native, Flutter, etc.)

**Features:**
- Design System Generator with 100 industry-specific reasoning rules
- Multi-domain search (products, styles, colors, typography, patterns)
- Stack-specific guidelines (React, Vue, SwiftUI, etc.)
- Pre-delivery checklist and anti-pattern detection

**Shared Resources:**
- Scripts and data files are located in `.shared/ui-ux-pro-max/` directory
- Python scripts for design system generation and search
- CSV data files for products, styles, colors, typography, etc.

## How Skills Work

Skills use **progressive disclosure** to efficiently manage context:

1. **Discovery**: Agent loads skill names and descriptions at conversation start (~100 tokens)
2. **Activation**: Agent reads full SKILL.md when task matches description (~5000 tokens)
3. **Execution**: Agent follows instructions, loading referenced files as needed

## Usage

Skills activate automatically based on task description. You can also explicitly mention skill names:

- "Use brainstorming to design a new feature"
- "Create an implementation plan using writing-plans"
- "Debug this issue using systematic-debugging"

## Skill Format

Each skill is a directory following the Agent Skills standard structure:

```
skill-name/
├── SKILL.md          # Required: Main instruction file with YAML frontmatter
├── scripts/          # Optional: Helper scripts (Python, Bash, etc.)
├── examples/         # Optional: Reference implementations
├── references/      # Optional: Additional documentation, templates
└── resources/        # Optional: Templates and other static resources
```

### SKILL.md (Required)

- **Frontmatter**: YAML metadata (name, description)
- **Instructions**: Markdown content explaining when and how to use the skill
- **Project-specific guidelines**: Tailored for Swift StateTree development

### Optional Directories

- **scripts/**: Executable scripts invoked by the agent (self-contained, handle edge cases)
- **examples/**: Reference implementations and code examples
- **references/**: Additional documentation, templates, detailed guides
- **resources/**: Static resources, diagrams, template files

These directories use progressive disclosure - loaded only when needed by the skill.

## Directory Structure

Skills can be organized in subdirectories for better management:

```
.agent/skills/
├── Superpowers/              # Superpowers framework skills
│   ├── brainstorming/
│   │   └── SKILL.md
│   ├── test-driven-development/
│   │   ├── SKILL.md
│   │   └── testing-anti-patterns.md  # Reference file
│   └── ...                   # All 14 Superpowers skills
├── SpecKit/                  # Spec-Driven Development workflow
│   ├── constitution/
│   │   └── SKILL.md
│   ├── specify/
│   │   └── SKILL.md
│   ├── clarify/
│   │   └── SKILL.md
│   ├── plan/
│   │   └── SKILL.md
│   ├── tasks/
│   │   └── SKILL.md
│   └── implement/
│       └── SKILL.md
├── SwiftStateTree/           # Project-specific skills
│   ├── run-e2e-tests/
│   │   └── SKILL.md
│   ├── view-pr-comments/
│   │   └── SKILL.md
│   ├── reply-pr-comment/
│   │   └── SKILL.md
│   ├── generate-schema/
│   │   └── SKILL.md
│   ├── deterministic-math-guidelines/
│   │   └── SKILL.md
│   └── swift-testing-guidelines/
│       └── SKILL.md
├── UI-UX-Pro-Max/            # UI/UX design intelligence
│   ├── SKILL.md
│   ├── scripts/              # Python scripts for design system generation
│   └── data/                 # CSV data files (products, styles, colors, etc.)
├── ProjectSpecific/          # Project-specific skills (future)
│   └── ...
└── README.md
```

**Shared Resources:**
```
.shared/
└── ui-ux-pro-max/            # Shared resources for UI-UX-Pro-Max skill
    ├── scripts/              # Python scripts
    └── data/                 # CSV data files
```

Skill names are based on their directory path (e.g., `Superpowers/brainstorming`).

Each skill directory can contain:
- `SKILL.md` (required)
- Optional: `scripts/`, `examples/`, `references/`, `resources/` subdirectories

## Adding New Skills

To add a new skill:

1. Choose location: `.agent/skills/your-category/your-skill-name/` or `.agent/skills/your-skill-name/`
2. Create `SKILL.md` with frontmatter and instructions
3. Follow the format of existing skills
4. Reference project guidelines from `AGENTS.md`

## References

- Agent Skills Standard: https://agentskills.io
- Antigravity Skills Docs: https://antigravity.google/docs/skills
- Superpowers Framework: https://github.com/obra/superpowers
- Spec-Kit (Spec-Driven Development): https://github.com/github/spec-kit
- UI-UX-Pro-Max Skill: https://github.com/nextlevelbuilder/ui-ux-pro-max-skill
- Project Guidelines: See `AGENTS.md` in project root
