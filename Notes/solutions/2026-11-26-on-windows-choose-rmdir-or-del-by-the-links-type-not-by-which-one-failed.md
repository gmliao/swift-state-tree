---
title: "On Windows, remove a link with rmdir or del chosen by its type, never by which one failed"
module: CI
date: 2026-11-26
problem_type: gotcha
component: windows-ci
symptoms:
  - "rmdir /q on a restored .build\\debug fails, and SwiftPM then warns \"unable to create symbolic link ... already exists in file system\""
  - "a del that was meant to remove only a link empties the top level of the directory it pointed to"
root_cause: del_on_a_directory_link_deletes_the_files_inside_its_target
resolution_type: code_fix
severity: medium
tags:
  - windows
  - ci
  - symlink
  - junction
  - cache
  - cmd
related:
  - "#845"
  - "#878"
  - "#890"
  - "#900"
---

# On Windows, remove a link with rmdir or del chosen by its type, never by which one failed

## Problem

The Windows job restores the build cache, which holds the `.build\debug` and `.build\release` links of the run that saved it. SwiftPM then warns `unable to create symbolic link ... already exists in file system` twice (Build and Tests) and `.build\debug` is the cache's link, not the build's own. The first fix (#900) ran `rmdir /q` on both. On a cache hit `.build\debug` was still there afterwards.

## What `rmdir` and `del` do to a link

`dir /AL .build` prints the type of each link. Three kinds matter, and a tool that is right for one is wrong for another (tried in a scratch folder on Windows 11):

| Type (the tag `dir /AL` prints) | `rmdir /q` | `del /q` |
|---|---|---|
| `<SYMLINK>` (file-type symlink, also to a directory) | fails (exit 11 here) | removes the link, target untouched |
| `<SYMLINKD>` (directory symlink) | removes the link, target untouched | did nothing here (exit 3) |
| `<JUNCTION>` | removes the link, target untouched | **deletes the top-level files inside the target** (exit 0) |
| a real directory | removes it only if empty | deletes the top-level files inside it |

So "try `rmdir`, and when it fails fall back to `del`" is wrong: an `rmdir` that fails on a directory link (access denied, a handle still open) falls through to a `del` that empties the target while the log says the link was removed.

## Fix

Read the type from `dir /AL .build` and choose the tool by it:

- a line matching `<SYMLINK> +<name>` (the tag followed by a space, so `<SYMLINKD>` does not match): `del /q`, and print the matched line in the log;
- anything else that exists: `rmdir /q` (a `<SYMLINKD>` or `<JUNCTION>` link goes, a real non-empty directory fails and is kept with a `::warning::` and the `dir /A` lines);
- nothing there: say it is absent (normal on a cache miss).

## Prevention

- Pick the removal tool by the link's type, never by "the other one failed". Print the line you matched, so the log shows which kind was found.
- Try a removal on a scratch folder holding every kind of link (file-type symlink, directory symlink, junction, a real non-empty directory) and look at the target afterwards, not only at the exit code.
- `rmdir /q` without `/s` is the safe default for anything that might be a real directory: it fails instead of deleting what is inside.
