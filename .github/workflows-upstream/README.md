# Upstream workflows (not active)

These are the CI and release workflows from 0xbow-io/privacy-pools-core, kept for reference. GitHub Actions only
runs files in `.github/workflows/`, so nothing here runs in this repository. Two of them publish the upstream SDK
to npm with upstream secrets, which must never run from this fork. ZKBLANK CI will be added under
`.github/workflows/` when it exists.
