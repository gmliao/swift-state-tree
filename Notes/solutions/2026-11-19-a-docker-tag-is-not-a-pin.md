---
title: "A Docker tag isn't a pin: the same tag pulled two images a day apart"
module: CI
date: 2026-11-19
problem_type: measurement_pitfall
component: toolchain-image
symptoms:
  - "the same image tag pulls a different digest on different days"
  - "performance runs on the pinned toolchain differ without a code change"
root_cause: a_docker_tag_is_mutable_and_was_pushed_again
resolution_type: design_rule
severity: medium
tags:
  - ci
  - docker
  - toolchain
  - measurement
  - methodology
related:
  - "#618"
---

**Problem.** CI, the devcontainer and every Dockerfile use `swift:6.2.4-noble`, and the repository calls that the pinned toolchain. While attributing a week of CI reruns, the job logs showed two digests for that one tag:
- `Digest: sha256:e508ef1e…` on 2026-11-11 (the last at 14:26 UTC);
- `sha256:3459518b…` from 2026-11-12 12:01 UTC on.

Both report `Swift version 6.2.4 (swift-6.2.4-RELEASE)`.

**Root cause.** A Docker tag is a mutable name. Official images are rebuilt and the tag is pushed again, for example when the Ubuntu base gets updates, without a change to the Swift version. So two runs "on the pinned toolchain" can use different images: the same compiler, but other system libraries.

**Fix.** #618 pins every Swift `image:` line in the workflows to one digest (`swift:6.2.4-noble@sha256:3459518b…`). `scripts/check-ci-image-pin.sh`, in the `shellcheck` job, fails when the lines differ, aren't pinned by digest, or a SwiftPM cache key doesn't name the digest.

**Prevention.**
- **A version string proves the compiler, not the image.** For a comparison that must hold the environment fixed, record the image digest next to `swift --version`. The job log's `Digest:` line, or `docker image inspect --format '{{index .RepoDigests 0}}'` on a host, gives it.
- **Before comparing numbers across a date,** check whether both sides pulled the same digest.
- **A tag in a Dockerfile `FROM` line can move too.** Pin it by digest when the build must be reproducible.
