# Omi Docs

This directory contains the local source for Omi's developer, API, hardware, and assembly documentation.

Start here:

- `INDEX.md` - complete local documentation index.
- `developer/repository-guide.mdx` - repository map, architecture, and day-to-day development commands.
- `developer/upstream-sync-and-backend-policy.mdx` - fork maintenance runbook and BasedHardware hosted backend policy.
- `doc/developer/backend/` - backend architecture and pipeline docs.
- `api-reference/` - API reference pages.

## Preview Locally

Install the Mintlify CLI:

```bash
npm i -g mintlify
```

Run from the docs root, where `docs.json` lives:

```bash
cd docs
mintlify dev
```

## Maintenance Rules

- Keep Adam's normal local builds on BasedHardware hosted services: `https://api.omi.me/` for the Python API and `https://desktop-backend-hhibjajaja-uc.a.run.app` for the hosted desktop backend.
- Update setup docs when changing scripts, required environment variables, signing, or Firebase assumptions.
- Update backend pipeline docs when changing audio streaming, transcription, conversation lifecycle, pusher/listen behavior, VAD, diarization, or speaker identification.
- Update hardware docs when changing firmware protocol, BLE characteristics, storage layout, or flashing behavior.
