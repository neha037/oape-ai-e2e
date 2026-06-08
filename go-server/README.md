# go-server — OAPE Workflow Orchestrator

The go-server is an HTTP orchestrator that accepts workflow requests via a REST API and runs the AI agent worker either as a **local subprocess** or as a **Kubernetes Job**.

## Execution Modes

The server supports two backends, selected via the `EXECUTION_MODE` environment variable:

| Mode | `EXECUTION_MODE` | Backend | Requirements |
|------|-------------------|---------|-------------|
| **Local** (default) | `local` | Spawns `python3.11 agent/main.py` as a subprocess | Python 3.11, agent dependencies |
| **Kubernetes** | `k8s` | Creates K8s Jobs with the agent-worker container | Kubernetes cluster, kubeconfig |

## Quick Start — Local Mode

No cluster needed. Just Go, Python, and a GitHub token.

```bash
cd go-server
export GH_TOKEN=$(gh auth token)
export CONFIG_DIR=../deploy/config
go run .
# => "Using local subprocess backend"
# => "OAPE server ready at http://localhost:8080"
```

Open http://localhost:8080 to use the UI.

### Prerequisites (local mode)

- **Go 1.23+** — [go.dev/dl](https://go.dev/dl/)
- **Python 3.11** with the agent dependencies installed (`pip install -r ../agent/requirements.txt`)
- **GitHub CLI (`gh`)** — authenticated (`gh auth login`)
- **`GH_TOKEN`** — set via `export GH_TOKEN=$(gh auth token)`

## Quick Start — K8s Mode

For production deployment on an OpenShift or Kubernetes cluster.

```bash
cd go-server
export EXECUTION_MODE=k8s
export GH_TOKEN=$(gh auth token)
export CONFIG_DIR=../deploy/config
export WORKER_IMAGE=quay.io/<your-username>/ai-agent:latest
go run .
# => "Using K8s backend (namespace=default)"
# => "OAPE server ready at http://localhost:8080"
```

### Prerequisites (K8s mode)

- Everything from local mode, plus:
- **A Kubernetes cluster** with kubeconfig at `~/.kube/config`
- **Worker container image** built and pushed (see [Building Images](#building-images))
- **Cluster resources**: ConfigMap `shift-worker-config` and Secret `gcloud-adc`

## Environment Variables

| Variable | Default | Mode | Description |
|---|---|---|---|
| `EXECUTION_MODE` | `local` | Both | `local` for subprocess, `k8s` for Kubernetes Jobs |
| `LISTEN_ADDR` | `:8080` | Both | Address the HTTP server binds to |
| `CONFIG_DIR` | `/config` | Both | Directory containing `team-repos.csv` |
| `GH_TOKEN` | *(none)* | Both | GitHub token (required in local mode; optional in K8s mode if ghpat sidecar is running) |
| `JIRA_PERSONAL_TOKEN` | *(none)* | Both | Jira PAT (optional; can also be provided per-request via the UI or API) |
| `PYTHON_BIN` | `python3.11` | Local | Python binary for running the agent |
| `AGENT_SCRIPT_PATH` | `../agent/main.py` | Local | Path to the agent entrypoint script |
| `GH_TOKEN_SERVICE_URL` | `http://localhost:8081` | K8s | URL of the GitHub token minter sidecar |
| `JOB_NAMESPACE` | auto-detected | K8s | Kubernetes namespace for workflow Jobs |
| `WORKER_IMAGE` | `quay.io/openshift-oap/ai-agent:latest` | K8s | Container image for the agent worker |
| `WORKER_ENV_CONFIGMAP` | `shift-worker-config` | K8s | ConfigMap injected into worker pods |
| `GCLOUD_SECRET_NAME` | `gcloud-adc` | K8s | Secret name for GCP credentials |
| `CONFIGS_CONFIGMAP` | `shift-worker-config` | K8s | ConfigMap mounted into worker pods |
| `TTL_AFTER_FINISHED` | `5400` (1h 30m) | K8s | Seconds before completed Jobs are cleaned up |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Homepage UI |
| `GET` | `/api/v1/repos` | List allowed repositories (from `team-repos.csv`) |
| `GET` | `/api/v1/workflows` | List all workflows |
| `GET` | `/api/v1/workflows/{job_id}` | Get workflow details |
| `POST` | `/api/v1/workflows` | Create a new workflow |
| `GET` | `/api/v1/workflows/{job_id}/log` | Stream workflow logs (SSE) |

### Create Workflow

The workflow accepts three input modes. At least one of `ep_url` or `jira_ticket` is required.

**EP-only (original):**
```bash
curl -X POST http://localhost:8080/api/v1/workflows \
  -H 'Content-Type: application/json' \
  -d '{
    "repo_url": "https://github.com/openshift/cert-manager-operator",
    "base_branch": "main",
    "ep_url": "https://github.com/openshift/enhancements/pull/1234"
  }'
```

**Jira-only (analyzes ticket, synthesizes design doc, generates code):**
```bash
curl -X POST http://localhost:8080/api/v1/workflows \
  -H 'Content-Type: application/json' \
  -d '{
    "repo_url": "https://github.com/openshift/cert-manager-operator",
    "base_branch": "main",
    "jira_ticket": "OCPBUGS-12345",
    "jira_token": "<your-jira-pat>"
  }'
```

**EP + Jira (EP for code generation, Jira ticket for review validation):**
```bash
curl -X POST http://localhost:8080/api/v1/workflows \
  -H 'Content-Type: application/json' \
  -d '{
    "repo_url": "https://github.com/openshift/cert-manager-operator",
    "base_branch": "main",
    "ep_url": "https://github.com/openshift/enhancements/pull/1234",
    "jira_ticket": "OCPBUGS-12345",
    "jira_token": "<your-jira-pat>"
  }'
```

| Field | Required | Description |
|---|---|---|
| `repo_url` | Yes | Target operator repository URL |
| `base_branch` | Yes | Branch to create feature branches from |
| `ep_url` | At least one of `ep_url` / `jira_ticket` | Enhancement Proposal PR URL |
| `jira_ticket` | At least one of `ep_url` / `jira_ticket` | Jira ticket key (e.g. `OCPBUGS-12345`) |
| `jira_token` | When `jira_ticket` is set | Jira Personal Access Token |

## Project Structure

```
go-server/
├── main.go          # Entry point — mode selection and HTTP routing
├── config.go        # Configuration from env vars + team-repos.csv
├── backend.go       # Backend interface (shared by both modes)
├── process.go       # Local subprocess backend
├── k8s.go           # Kubernetes Job backend
├── handlers.go      # HTTP handlers for all API endpoints
├── go.mod / go.sum  # Go module dependencies
└── static/
    └── homepage.html  # Embedded UI served at /
```

## Building Images

```bash
# From the repo root
podman build -t oape-ai:go-server -f images/go-server.Dockerfile .
podman build -t oape-ai:agent-worker -f images/agent-worker.Dockerfile .
podman build -t oape-ai:gh-token-minter -f images/gh-token-minter.Dockerfile .
```

## Full Production Deployment (K8s)

```bash
kubectl apply -k deploy/
```

See `deploy/deployment.yaml` for the full manifest including RBAC, Service, and Route.

## Troubleshooting

| Problem | Fix |
|---|---|
| `failed to load config` | Set `CONFIG_DIR=../deploy/config` |
| `failed to create k8s client` (K8s mode) | Ensure kubeconfig at `~/.kube/config` and cluster is reachable |
| `failed to fetch GitHub token` | Set `export GH_TOKEN=$(gh auth token)` |
| `starting agent process: exec: "python3.11": executable file not found` | Install Python 3.11 or set `PYTHON_BIN=python3` |
| `Stream connection lost` (K8s mode) | Check pod status: `kubectl get pods -l app=shift-worker` |
| `address already in use` | Kill process on port 8080 or set `LISTEN_ADDR=:9090` |
