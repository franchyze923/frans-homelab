# Argo CD App of Apps — Minimal Example

This repo shows a tiny App-of-Apps pattern with two child apps (hello-a, hello-b).

## Files
- `apps/app-of-apps.yaml` — Parent Application that points to the `apps/` folder.
- `apps/hello-a.yaml` / `apps/hello-b.yaml` — Child Argo CD Applications.
- `workloads/hello-a/k8s.yaml` / `workloads/hello-b/k8s.yaml` — Simple nginx Deployments + Services.

## Usage
1. Replace the placeholder repo URL in the YAMLs:
   `https://github.com/<YOU>/<YOUR-REPO>.git` and branch `main`.
2. Commit and push to your repo.
3. Apply the parent application to your cluster:
   ```bash
   kubectl apply -n argocd -f apps/app-of-apps.yaml
   ```
4. Argo CD will create and sync the child apps automatically.

## Test
```bash
kubectl -n hello-a port-forward svc/web 8080:80
curl -s localhost:8080  # -> "Hello from A"
```

## Notes
- Requires Argo CD to allow creation of `Application` resources.
- Parent uses `directory.recurse: true` to pick up all child Application yamls in `apps/`.
- Both child apps enable auto-sync with prune + self-heal.
# app-of-apps
