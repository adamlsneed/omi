# Fork reference archive

Current development instructions live in the [repository agent guide](../../../AGENTS.md),
[fork rules](../fork-rules.md), [upstream sync guide](../upstream-sync.md),
[iPhone and Watch guide](../ios-install.md), and
[desktop guide](../../../desktop/macos/AGENTS.md).

The adjacent files retain historical fork architecture notes previously under
`docs/`. Code-review evidence lives in [the report archive](../../reports/fork-reference/). Consult the current guides before using older
commands or endpoint examples. The public developer site lives in `docs/`; internal
runbooks belong beside their owning code or under `.github/agent-docs/`.

## Preview the public documentation

Install the Mintlify CLI and run its preview from the repository's `docs/` directory:

```bash
npm i -g mintlify
cd docs
mintlify dev
```

Update the owning guide alongside setup, signing, backend routing, audio pipeline,
or device protocol changes. Current hosted service defaults are owned by the fork
and component guides, not this archive.
