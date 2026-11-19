#!/usr/bin/env python3
"""The Turns documentation's Swift blocks appear in its tested files, without a build.

The same comparison as SwiftStateTurnsTests' "Every Swift block in the documentation appears in
the tested files" (Tests/SwiftStateTurnsTests/WorkedExampleTests.swift, documentationMatchesTheTests):
every ```swift block of the DocC catalog (Sources/SwiftStateTurns/SwiftStateTurns.docc/*.md) and of
docs/turns/README.md and README.zh-TW.md must appear in WorkedExampleTests.swift,
ComparisonTests.swift or ConceptsTests.swift, each line compared without its leading spaces. That
test needs a build; this runs in pre-push-checks.sh, so a docs edit pushed without one can't turn
main red. Like the test, it requires at least MIN_BLOCKS blocks, so fences that stop matching
fail instead of passing on none. Files are read with their newlines kept, as Swift reads them.
Keep the two in step: a change to the test's rule changes this script.

Usage: scripts/check-turns-doc-blocks.py [--self-test] [repo root]
"""
import sys
import tempfile
from pathlib import Path

CATALOG = Path("Sources/SwiftStateTurns/SwiftStateTurns.docc")
PAGES = [Path("docs/turns/README.md"), Path("docs/turns/README.zh-TW.md")]
TESTS = Path("Tests/SwiftStateTurnsTests")
SOURCES = ["WorkedExampleTests.swift", "ComparisonTests.swift", "ConceptsTests.swift"]
FENCE = "`" * 3
# WorkedExampleTests.swift: `#expect(blocks >= 20)`.
MIN_BLOCKS = 20


def read(path: Path) -> str:
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def flat(text: str) -> str:
    return "\n".join(line.lstrip(" ") for line in text.split("\n"))


def check(root: Path, min_blocks: int = MIN_BLOCKS) -> list[str]:
    """The findings: one per block that no tested file contains, and one for too few blocks."""
    articles = sorted((root / CATALOG).glob("*.md"))
    if not articles:
        return [f"{CATALOG.as_posix()}: no .md file (the test reads the catalog's articles)"]
    pages = articles + [root / p for p in PAGES]
    source = flat("\n".join(read(root / TESTS / name) for name in SOURCES))
    findings = []
    blocks = 0
    for page in pages:
        text = read(page)
        for block in text.split(FENCE + "swift\n")[1:]:
            blocks += 1
            block = block.split(FENCE)[0]
            if flat(block) not in source:
                first = next((line for line in block.split("\n") if line.strip()), "")
                findings.append(f"{page.relative_to(root).as_posix()}: a Swift block in no tested file, starting: {first.strip()}")
    if blocks < min_blocks:
        findings.append(f"{blocks} Swift block(s) found, the test requires at least {min_blocks}")
    return findings


def self_test() -> bool:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / CATALOG).mkdir(parents=True)
        (root / PAGES[0].parent).mkdir(parents=True)
        (root / TESTS).mkdir(parents=True)
        block = FENCE + "swift\nstruct Room {\n    var seats: Int\n}\n" + FENCE + "\n"
        (root / CATALOG / "Article.md").write_text("Text.\n\n" + block, encoding="utf-8", newline="")
        for page in PAGES:
            (root / page).write_text(block, encoding="utf-8", newline="")
        # Indented differently in the test: still found.
        (root / TESTS / SOURCES[0]).write_text("enum E {\n        struct Room {\n            var seats: Int\n        }\n}\n", encoding="utf-8", newline="")
        for name in SOURCES[1:]:
            (root / TESTS / name).write_text("", encoding="utf-8", newline="")
        if check(root, min_blocks=3):
            print("self-test: a block the tests contain was reported")
            return False
        if not any("at least 4" in f for f in check(root, min_blocks=4)):
            print("self-test: too few blocks were not reported")
            return False
        (root / PAGES[1]).write_text(block + "\n" + FENCE + "swift\nlet missing = 1\n" + FENCE + "\n", encoding="utf-8", newline="")
        findings = check(root, min_blocks=3)
        if len(findings) != 1 or "README.zh-TW.md" not in findings[0] or "let missing = 1" not in findings[0]:
            print(f"self-test: wanted one finding for the missing block, got {findings}")
            return False
        (root / CATALOG / "Article.md").unlink()
        if not any("no .md file" in f for f in check(root, min_blocks=0)):
            print("self-test: an empty catalog was not reported")
            return False
    print("check-turns-doc-blocks: self-test passed")
    return True


def main(argv: list[str]) -> int:
    if argv[:1] == ["--self-test"]:
        return 0 if self_test() else 1
    root = Path(argv[0]) if argv else Path(__file__).resolve().parent.parent
    findings = check(root)
    for finding in findings:
        print(finding)
    print(f"check-turns-doc-blocks: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
