---
module: SwiftStateTreeNIO
date: 2026-11-25
problem_type: bug_class
component: reevaluation-registration
symptoms:
  - "opening a replay viewer or the reevaluation monitor calls the game's services factory"
  - "a services factory is called with a replay or monitor land ID"
  - "production dependencies are built for a land that resolves nothing"
root_cause: per_land_factory_set_before_the_derived_configurations_were_copied
resolution_type: code_fix
severity: medium
tags:
  - configuration
  - copy
  - services
  - replay
  - monitor
related:
  - "#769"
  - "#825"
---

## Problem

The typed `registerWithGenericReplay(…liveLand:services:…)` set the live land's services factory on the configuration, then passed it to the untyped overload, which derives the replay land's configuration and the monitor land's configuration from it. Both copies kept the factory. `LandManager` calls the factory for every land it builds, so opening a replay viewer or a monitor ran the game's factory with the alias's or the monitor's ID and metadata.

## Root cause

A configuration value is copied to make the configurations of related lands, and a copy keeps every field. A field that belongs to one land (its services factory) leaked into the others because nothing cleared it. Registration didn't notice: the replay and monitor lands declare no services, so a factory they don't need passes every check.

## Fix

Both derived configurations drop the factory: the replay configuration right after it is built, `monitorLandConfiguration` for the monitor (#825 round 1). A host-level test registers a typed land, opens a live, a monitor and a replay land, and checks that a spy factory was called for the live land type only; it failed before the fix with all three types.

## Prevention

- When a configuration is derived from another, list the fields that belong to the original's land only (factories, per-land hooks, identity) and reset them in the derivation, next to the fields it overrides.
- Test it at the level that builds the lands (the host), with a spy on the field, since a registration check passes either way.
