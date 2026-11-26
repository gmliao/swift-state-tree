---
title: "Read the failing CI log's codes before calling a test a flake"
module: process
date: 2026-11-26
problem_type: testing_practice
component: ci-triage
symptoms:
  - "a test fails only on one CI leg and is called timing-dependent"
  - "the fix makes the test wait longer or on an event, and the cause stays"
root_cause: triage_from_the_assertion_without_the_log_s_error_and_close_codes
resolution_type: established_pattern
severity: low
tags:
  - ci
  - triage
  - flake
related:
  - "#912"
  - "2026-11-26-a-close-decided-in-one-component-must-be-seen-by-the-others-in-its-segment"
---

# Read the failing CI log's codes before calling a test a flake

## Problem

#912's test failed on macOS CI only: the JOIN_INBOUND_OVERFLOW error never arrived. It was treated as a slow-runner timing problem, and the change replaced its 5 s read deadline with an event wait. But the macOS log already named the cause. It shows nine JOIN_SESSION_NOT_CONNECTED refusals and the line "Too many refused frames before join; closing the session budget=8": a second close (1008) overtook the error. That's a bug in the product, not in the test's timing.

## Root cause

The triage read the failing assertion, not the error codes, close codes and log lines the run printed around it.

## Prevention

- Before calling a failure a flake, read the failing run's log for every error code, close code and warning on the session the test watches. List what the client got, in order, and compare it with what the test expects.
- A deadline change or an event wait is a fix only when the log shows the expected frames arriving late. When the log shows other frames or another close code, look for a second decision.
