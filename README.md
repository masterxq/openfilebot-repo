# OpenFileBot APT Repository Publisher

This repository automatically publishes a signed Debian APT repository for OpenFileBot.

- Source releases: `masterxq/openfilebot`
- Published site: GitHub Pages from `gh-pages`
- Retention policy:
  - `stable`: latest 5 non-prerelease GitHub releases
  - `testing`: latest 5 GitHub releases including prereleases

## Channels

- Prerelease => `testing` only
- Release => `stable` and `testing`

## Automation

- Runs every hour via GitHub Actions schedule
- Can be run manually with `workflow_dispatch`
- No manual package index maintenance required

Public keys are published in `apt/keyrings/`.
