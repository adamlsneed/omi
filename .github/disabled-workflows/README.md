# Disabled GitHub Workflows

This fork runs against BasedHardware's hosted backend services and must never
deploy fork-owned backends or auto-release the desktop app on pushes to `main`.
Two mechanisms keep upstream's automation off:

## Files moved out of `.github/workflows/`

Workflows in this directory were moved here so they cannot trigger at all. When
an upstream sync brings one of them back, move it here again.

- `desktop_backend_auto_dev.yml`
- `gcp_backend_agent_proxy_auto_deploy.yml`
- `gcp_backend_auto_dev.yml`
- `gcp_backend_listen_helm.yml`
- `gcp_cloud_run_metrics_egress.yml`
- `gcp_daily_memory_sweep_job_auto_dev.yml`
- `gcp_day3_reengagement_email_job_auto_dev.yml`
- `runtime_image_contracts.yml`

## Disabled in the repository's Actions settings

Some workflows stay in `.github/workflows/` byte-identical to upstream because
contract checks read them by path. They are disabled with
`gh workflow disable <id> -R adamlsneed/omi`, which survives syncs. Audit with:

```bash
gh api --paginate repos/adamlsneed/omi/actions/workflows \
  --jq '.workflows[] | "\(.state)\t\(.name)\t\(.path)"' | grep -v '^active'
```

As of 2026-09-02 that list includes `desktop_auto_release.yml`,
`gcp_backend_pusher_auto_deploy.yml`, `gcp_memory_maintenance_job_auto_dev.yml`,
`desktop_release_doctor.yml`, `gcp_firestore_indexes.yml`, `publish_omi_cli.yml`,
`backend-unit-tests.yml`, `parakeet_gpu_tests.yml`, `sync-docs.yml`,
`pr-declined-comment.yml`, and every `Deploy ... to Cloud Run/GKE` workflow.
`desktop_promote_prod.yml` and `desktop_codemagic_failure_recovery.yml` are
manual-dispatch only and stay active.

Local desktop builds use the hosted pair that `desktop/macos/run.sh --yolo` exports:

```text
OMI_DESKTOP_API_URL=https://desktop-backend-dt5lrfkkoa-uc.a.run.app
OMI_PYTHON_API_URL=https://api.omiapi.com
```
