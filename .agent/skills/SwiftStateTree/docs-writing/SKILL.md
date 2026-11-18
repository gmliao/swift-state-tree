---
name: docs-writing
description: Use when writing, revising or polishing any SwiftStateTree documentation a reader sees — pages under docs/ (English and .zh-TW.md), DocC catalogs (*.docc), README.md and README.zh-TW.md — including translating a page, adding a section, or a "make it read more smoothly" pass.
---

# Writing SwiftStateTree documentation

## Overview

The target style is a textbook. A reader who knows Swift but not this project should follow each page from top to bottom without looking anything up.

**Announce at start:** "I'm using the docs-writing skill."

## Sentences and terms

- Short sentences, one idea each.
- Define a term before you use it. Gloss a term of art at its first use.
- Use the same term every time. Don't switch between synonyms for variety.
- Prefer a plain word where jargon isn't needed.
- Give a concrete example where it helps.
- No emphasis words: significantly, dramatically, simply, just, obviously.
- No bare letter codes or internal labels. Don't write "rule 7", "check 28", "M1" or a plan's step number in user docs; name what the thing is ("the FIFO rule for parked inputs").

## Choosing how to explain a concept

- **Always start plain.** The first sentence says what it is in everyday words, with no other new term in it.
- **Then an example**, by default, when the concept is about behaviour: a short compiled code example, or a concrete game scenario ("a player leaves while their profile loads").
- **A picture when the point is structure or order over time:** layers, or who waits behind whom. Use one when text would need more than about three sentences of "then… then…".
  - Hand-written SVG: an explicit light background with dark strokes (readable in light and dark themes), plain shapes and text, no external fonts, a `viewBox`, alt text, about 10 KB or less.
  - English labels, shared by both languages; a `.zh-TW.svg` copy only when the zh-TW page needs Chinese labels.
  - In DocC, put the file in the catalog's `Resources/` and use `@Image(source:alt:)`.
  - The picture repeats what the text says, and adds nothing. The text stays complete without it, because a test can't check a picture.
- Don't use all three where one does the job.

## Paragraphs

- Order: what it shows, then how (or the evidence), then its limit.
- A long condition goes at the paragraph's end ("Limit: …"), not in the middle of a sentence.
- State a caveat in full once. Elsewhere, link to it.
- No self-defensive disclaimers.

## Code examples

- Short, in a language-tagged fence (```swift).
- Compiled by a test where possible: the page's blocks must appear in a test file, and a test checks that they do (see `Tests/SwiftStateTurnsTests/WorkedExampleTests.swift`, `documentationMatchesTheTests`). Change the test file first, then copy the block.

## Bilingual pages (zh-TW)

AGENTS.md's bilingual rule applies: every change to `docs/<x>.md` goes into `docs/<x>.zh-TW.md` in the same change.

- The zh-TW page is a translation, not a separate text: same sections, same claims, same examples.
- Natural Traditional Chinese with short sentences.
- Component and type names stay in English, with a short Chinese gloss at first use (`TurnCore`（機制）).
- The same Chinese term every time.

## A polish pass

A polish pass changes wording only.

1. Keep a copy of the text before the pass.
2. Change no claim, condition, number, name or link.
3. Review as a newcomer: someone who knows Swift but not this project. Mark every term used before it is defined.
4. Compare with the copy, paragraph by paragraph, for meaning drift. A sentence that now says more or less than before is reverted.
5. For a bilingual page, polish both versions and check that they still say the same thing.

## Common mistakes

| Mistake | Fix |
|---|---|
| A plan's rule number in a user page | Name the rule |
| A caveat repeated in three places | State it once, link to it |
| "simply call `send`" | "call `send`" |
| A zh-TW page that adds or drops a sentence | Translate the English page as it is |
| A code block edited only in the page | Edit the test file, then copy the block |
