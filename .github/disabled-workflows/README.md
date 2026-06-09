# Disabled GitHub Workflows

The backend deployment workflows in this directory are intentionally stored
outside `.github/workflows`. This fork must use BasedHardware's hosted backend
services and must not deploy fork-owned replacements on pushes to `main` or as
part of a desktop release.

Disabled automatic deployment workflows:

- `desktop_auto_release.yml`
- `desktop_backend_auto_dev.yml`
- `gcp_backend_auto_dev.yml`
- `gcp_backend_listen_helm.yml`
- `gcp_backend_pusher_auto_deploy.yml`
- `gcp_backend_agent_proxy_auto_deploy.yml`

Local desktop builds should use:

```text
OMI_DESKTOP_API_URL=https://desktop-backend-hhibjajaja-uc.a.run.app/
OMI_PYTHON_API_URL=https://api.omi.me
```
