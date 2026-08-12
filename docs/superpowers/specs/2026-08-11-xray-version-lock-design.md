# Xray Version Lock Design

## Goal

Lock this fork of 3x-ui to Xray-core `v26.6.27`.

## Scope

- Release builds must package Xray-core `v26.6.27` by default.
- Docker initialization must download Xray-core `v26.6.27` by default.
- The panel Xray version picker and install endpoint must expose and accept only `v26.6.27`.

## Non-goals

- Do not change the 3x-ui panel version.
- Do not remove historical Git tags or GitHub releases.
- Do not change unrelated Xray configuration behavior.

## Implementation

- Replace hardcoded release download URLs from `v26.7.28` to `v26.6.27`.
- Replace the dynamic Xray release filter with a fixed allowlist containing only `v26.6.27`.
- Keep the existing `UpdateXray` validation path so direct API calls for other versions are rejected.

## Verification

- Search the source for old default Xray versions.
- Run Go tests for the server service package if the local Go toolchain supports this repository's Go version.
