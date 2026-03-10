# oape-ai-e2e

AI-driven Feature Development tools.

## Pre-requisites

The following tools must be installed and available on your system:

- **Git**
- **Go**: [go.dev/dl](https://go.dev/dl/)
- **GitHub CLI (`gh`)**: [cli.github.com](https://cli.github.com/)
- **make**: eg. `make generate`, `make build`, etc.

The container image used in [Dockerfile](./Dockerfile) already adds these dependencies, but you need to manage the credentials inside the container.

### Optional

- **`JIRA_PERSONAL_TOKEN`** environment variable -- required only for `/oape:analyze-rfe` (Jira API access).

## Installation

Add the marketplace:
```shell
/plugin marketplace add shiftweek/oape-ai-e2e
```

Install the plugin:
```shell
/plugin install oape@oape-ai-e2e
```

Use the commands:
```shell
/oape:api-generate https://github.com/openshift/enhancements/pull/1234
```

## Updating Plugins

Update the marketplace (fetches latest plugin catalog):
```shell
/plugin marketplace update oape-ai-e2e
```

Reinstall the plugin (downloads new version):
```shell
/plugin install oape@oape-ai-e2e
```

## Using Cursor

Cursor can discover the commands by symlinking this repo into your `~/.cursor/commands` directory:

```bash
mkdir -p ~/.cursor/commands
git clone git@github.com:shiftweek/oape-ai-e2e.git
ln -s oape-ai-e2e ~/.cursor/commands/oape-ai-e2e
```

## Available Plugins

| Plugin | Description | Commands |
| ------------------------- | ---------------------------------------------- | --------------------------------------------------------------------------- |
| **[oape](plugins/oape/)** | AI-driven OpenShift operator development tools | `/oape:init`, `/oape:api-generate`, `/oape:api-generate-tests`, `/oape:api-implement`, `/oape:analyze-rfe`, `/oape:e2e-generate`, `/oape:predict-regressions`, `/oape:review`, `/oape:implement-review-fixes` |

## Commands

### `/oape:init` -- Clone an Operator Repository

Clones an allowed OpenShift operator repository by short name into the current directory.

```shell
/oape:init cert-manager-operator
```

### `/oape:api-generate` -- Generate API Types from Enhancement Proposal

Reads an OpenShift enhancement proposal PR, extracts the required API changes, and generates compliant Go type definitions in the correct paths of the current OpenShift operator repository.

```shell
/oape:api-generate https://github.com/openshift/enhancements/pull/1234
```

### `/oape:api-generate-tests` -- Generate Integration Tests for API Types

Generates `.testsuite.yaml` integration test files for OpenShift API type definitions, covering create, update, validation, and error scenarios.

```shell
/oape:api-generate-tests api/v1alpha1/myresource_types.go
```

### `/oape:api-implement` -- Generate Controller Implementation from Enhancement Proposal

Reads an OpenShift enhancement proposal PR, extracts the required implementation logic, and generates complete controller/reconciler code following controller-runtime and operator-sdk conventions.

```shell
/oape:api-implement https://github.com/openshift/enhancements/pull/1234
```

### `/oape:analyze-rfe` -- Analyze RFE and Generate EPIC/Stories Breakdown

Analyzes a Jira Request for Enhancement (RFE) and produces a structured breakdown of Epics, user stories, and outcomes. Requires `JIRA_PERSONAL_TOKEN` for Jira API access.

```shell
/oape:analyze-rfe RFE-7841
/oape:analyze-rfe https://issues.redhat.com/browse/RFE-7841
```

### `/oape:e2e-generate` -- Generate E2E Test Artifacts

Generates e2e test artifacts by discovering the repo structure and analyzing the git diff from a base branch.

```shell
/oape:e2e-generate main
```

### `/oape:predict-regressions` -- Predict API Regressions and Breaking Changes

Analyzes git diff to predict potential regressions, breaking changes, and backward compatibility issues. Combines static analysis with LLM-powered semantic analysis.

```shell
/oape:predict-regressions main
/oape:predict-regressions origin/release-4.18 --output .reports
```

### `/oape:review` -- Code Review Against Jira Requirements

Performs a production-grade code review that verifies code changes against Jira requirements.

```shell
/oape:review OCPBUGS-12345
/oape:review OCPBUGS-12345 origin/release-4.15
```

### `/oape:implement-review-fixes` -- Apply Fixes from Review Report

Automatically applies code fixes from a review report.

```shell
/oape:implement-review-fixes <report-path>
```

**Typical workflow:**
```shell
# Step 1: Clone the operator repository
/oape:init cert-manager-operator

# Step 2: Generate API types
/oape:api-generate https://github.com/openshift/enhancements/pull/1234

# Step 3: Generate integration tests
/oape:api-generate-tests api/v1alpha1/

# Step 4: Predict potential regressions
/oape:predict-regressions main

# Step 5: Generate controller implementation
/oape:api-implement https://github.com/openshift/enhancements/pull/1234

# Step 6: Generate e2e tests for your changes
/oape:e2e-generate main
```

## Deployment

Deploy the Python web server to run as a container or as a pod on a Kubernetes cluster. The web traffic port on the container is 8000.

### Build the container image

```shell
podman build -t ghcr.io/shiftweek/oape-ai-e2e:latest .
podman push ghcr.io/shiftweek/oape-ai-e2e:latest
```

### Configure the deployment

Edit `deploy/deployment.yaml` and fill in the required values which are placeholders for sensitive values.

### Deploy on a k8s cluster

```shell
oc apply -f deploy/deployment.yaml   # or kubectl apply -f deploy/deployment.yaml
```

### Adding a New Command

1. Add a new markdown file under `plugins/oape/commands/`
2. The command will be available as `/oape:<command-name>`
3. Update the plugin `README.md` documenting the new command

### Plugin Structure

```text
plugins/oape/
├── ztwim-test-generator/   # ZTWIM fixtures, docs, skills (commands are in commands/)
├── .claude-plugin/
│   └── plugin.json           # Required: plugin metadata
├── commands/
│   └── <command-name>.md     # Slash commands
├── skills/
│   └── <skill-name>/
│       └── SKILL.md          # Reusable agent skills (optional)
└── README.md                 # Plugin documentation
```
