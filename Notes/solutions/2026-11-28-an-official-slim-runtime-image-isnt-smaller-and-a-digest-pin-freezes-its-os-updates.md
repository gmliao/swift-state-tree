---
title: "An official -slim runtime image isn't smaller than a hand-built one, and a digest pin freezes its OS updates"
module: Docker
date: 2026-11-28
problem_type: measurement_pitfall
component: runtime-image
symptoms:
  - "switching the runtime stage to swift:<version>-noble-slim makes the images larger, not smaller"
  - "the slim image's packages are older than the ubuntu tag the hand-built stage used"
  - "a stale slim digest under a new tag passes the pin check"
root_cause: the_slim_image_ships_what_the_hand_built_stage_listed_plus_more_and_its_digest_is_its_build_day
resolution_type: design_rule
severity: low
tags:
  - docker
  - runtime-image
  - digest-pin
  - security-updates
  - measurement
related:
  - "#848"
  - "#989"
  - "Notes/solutions/2026-11-19-a-docker-tag-is-not-a-pin.md"
---

## Problem

#848 proposed running the DemoServer and GameServer images on the official `swift:6.4.3-noble-slim` runtime image instead of the hand-built stage (`FROM ubuntu:24.04`, an `apt-get install` list, and the Swift runtime libraries copied from the builder). The expected win was a smaller image and no hand-kept package list. #989 made the change and measured it on a Linux cloud worker (base 24658c3f, head cd46a9d3):

- **Sizes went up.** DemoServer 465 → 482 MB, GameServer 537 → 555 MB (+17 and +18 MB).
- **Nothing was missing.** `ldd` reported no `=> not found` in any of the four images (both servers, base and head). `lib_FoundationICU` and `/etc/ssl/certs/ca-certificates.crt` were present in all four, and all four started and listened.
- **Packages differed.** `libatomic1` was absent in the slim image, and `ldd` shows the binaries don't need it. `tzdata` was 2026e in the slim image and 2026f in the hand-built one. `ca-certificates`, `libcurl4t64`, `libicu74` and `libxml2` were the same versions.
- The Docker E2E passed on the slim image (json, jsonOpcode and messagepack, every scenario, re-evaluation record and verify included) once the E2E script set the admin key and the debug state routes, which it had lacked since `assertConverged` landed.

The maintainer kept the hand-built stage. #848 stays open, deferred.

## Root cause

- "Slim" is slim against the full toolchain image, not against a stage built for one binary. The slim image carries the Swift runtime for any program; the hand-built stage carried what these servers need and copied only the runtime libraries they link. The switch added 17–18 MB. Which files make up the difference wasn't measured.
- A digest pin fixes the image to the day swift-docker built it. The hand-built stage pulled `ubuntu:24.04` by tag and ran `apt-get install`, so every rebuild got the current Ubuntu packages. Pinned by digest, the slim image's packages, security fixes included, stay as they were until the next toolchain bump moves the pin. They already lagged the `ubuntu:24.04` tag on the day of the measurement (tzdata 2026e vs 2026f).
- The pin check can't tell a stale slim digest from a current one. Docker pulls by the digest and ignores the tag when both are given, and nothing ties the slim digest to its tag. At a bump that moves the tags and the build digest but forgets the slim digest, the old `6.4.3-noble-slim` digest under a `6.4.4-noble-slim` tag passes: it differs from the build digest, and both files share it. The image then runs the previous runtime under a binary built by the new toolchain. The build digest has the same blind spot, but CI runs that image, so a stale one shows in `swift --version`; the slim image runs only in the Docker E2E.

## Prevention

- Measure an image change before claiming its win. Record both sides' sizes and `dpkg -l`, run `ldd` on the binaries, and look for `=> not found`, not for "not found" anywhere in the report: the report's own header text contains it.
- Before pinning an OS image by digest, weigh the cost: no OS or security update until the pin moves. A stage that pulls the distro by tag and installs its packages gets them at each rebuild.
- A digest pinned next to a tag needs its own cross-check: resolve the tag (`docker buildx imagetools inspect`) and compare it with the digest, or name every digest in the bump checklist.
- What would reopen #848: a size win on a later toolchain, or a need to drop the hand-kept apt list.
