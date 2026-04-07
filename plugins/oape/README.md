# oape Plugin

AI-driven OpenShift operator development tools, following OpenShift and Kubernetes API conventions.

## Commands

### `/oape:init`

Clones an OpenShift operator git repository by URL into the current directory and checks out the specified base branch so that subsequent `/oape:*` commands can operate immediately.

**Usage:**
```shell
/oape:init <git-url> <base-branch>
```

**Example:**
```shell
/oape:init https://github.com/openshift/cert-manager-operator main
```

**What it does:**
1. **Prechecks** -- Validates both arguments (git URL and base branch) and required tools (`git`).
2. **Clone** -- Runs `git clone --filter=blob:none` into the current working directory. If the directory already exists with the correct remote, reuses it.
3. **Checkout** -- Checks out the specified base branch.
4. **Verify** -- Changes into the cloned directory and reports the Go module and detected framework.

### `/oape:api-generate`

Reads an OpenShift enhancement proposal PR, extracts the required API changes, and generates compliant Go type definitions in the correct paths of the current OpenShift operator repository.

**Usage:**
```shell
/oape:api-generate https://github.com/openshift/enhancements/pull/1234
```

**What it does:**
1. **Prechecks** -- Validates the PR URL, required tools (`gh`, `go`, `git`), GitHub authentication, repository type (must be an OpenShift operator repo with `openshift/api` dependency), and PR accessibility. Fails immediately if any precheck fails.
2. **Knowledge Refresh** -- Fetches and internalizes the latest OpenShift and Kubernetes API conventions before generating any code.
3. **Enhancement Analysis** -- Reads the enhancement proposal to extract API group, version, kinds, fields, validation requirements, feature gate info, and whether it is a configuration or workload API.
4. **Code Generation** -- Generates or modifies Go type definitions following conventions derived from the authoritative documents and patterns from the existing codebase.
5. **FeatureGate Registration** -- Adds FeatureGate to `features.go` when applicable.

### `/oape:api-generate-tests`

Generates `.testsuite.yaml` integration test files for OpenShift API type definitions. Reads Go types, CRD manifests, and validation markers to produce comprehensive test suites.

**Usage:**
```shell
/oape:api-generate-tests api/v1alpha1/myresource_types.go
```

**What it does:**
1. **Prechecks** -- Verifies the repository, identifies target API types, and checks for CRD manifests.
2. **Type Analysis** -- Reads Go types to extract fields, validation markers, enums, unions, immutability rules, and feature gates.
3. **Test Generation** -- Generates test cases covering: minimal valid create, valid/invalid field values, update scenarios, immutable fields, singleton name validation, discriminated unions, feature-gated fields, and status subresource tests.
4. **File Output** -- Writes `.testsuite.yaml` files following the repo's existing naming and directory conventions.

### `/oape:api-implement`

Reads an OpenShift enhancement proposal PR, extracts the required implementation logic, and generates complete controller/reconciler code following controller-runtime and operator-sdk conventions.

**Usage:**
```shell
/oape:api-implement https://github.com/openshift/enhancements/pull/1234
```

**What it does:**
1. **Prechecks** -- Validates the PR URL, required tools (`gh`, `go`, `git`, `make`), GitHub authentication, repository type (controller-runtime or library-go), and PR accessibility.
2. **Knowledge Refresh** -- Fetches and internalizes the latest controller-runtime patterns and operator best practices.
3. **Enhancement Analysis** -- Reads the enhancement proposal to extract business logic requirements, reconciliation workflow, conditions, events, and error handling.
4. **Pattern Detection** -- Identifies the controller layout pattern used in the repository.
5. **Code Generation** -- Generates complete Reconcile() logic, SetupWithManager, finalizer handling, status updates, and event recording.
6. **Controller Registration** -- Adds the new controller to the manager.

### `/oape:analyze-rfe`

Analyzes a Jira Request for Enhancement (RFE) and generates a structured breakdown of Epics, user stories, and their outcomes. Requires `JIRA_PERSONAL_TOKEN` for Jira API access.

**Usage:**
```shell
/oape:analyze-rfe RFE-7841
/oape:analyze-rfe https://issues.redhat.com/browse/RFE-7841
```

**What it does:**
1. **Fetch RFE** -- Retrieves the RFE from Jira (REST API).
2. **Parse** -- Extracts nature, description, desired behavior, affected components.
3. **Workspace context** (optional) -- Uses `context.md` files (e.g. `docs/component-context/context.md`) when present to enrich scope and key areas.
4. **Generate EPIC(s)** -- Objective, scope, acceptance criteria.
5. **Generate user stories** -- "As a... I want... So that..." with acceptance criteria and outcomes.
6. **Output** -- Markdown report; optionally saved to `.work/jira/analyze-rfe/<rfe-key>/breakdown.md`.

**Typical Workflow:**
```shell
# Clone the operator repository (if not already cloned)
/oape:init cert-manager-operator

# Generate the API types
/oape:api-generate https://github.com/openshift/enhancements/pull/1234

# Generate integration tests for the new types
/oape:api-generate-tests api/v1alpha1/myresource_types.go

# Predict potential regressions
/oape:predict-regressions main

# Generate the controller implementation
/oape:api-implement https://github.com/openshift/enhancements/pull/1234
```

---

### `/oape:predict-regressions`

Analyzes git diff to predict potential regressions, breaking changes, and backward compatibility issues in newly developed APIs.

**Usage:**
```shell
/oape:predict-regressions main
/oape:predict-regressions origin/release-4.18 --output .reports
```

**What it does:**
1. **Prechecks** -- Validates base branch exists, verifies repository is a valid OpenShift operator, and confirms non-empty git diff.
2. **Diff Extraction** -- Collects all API type changes, CRD schema changes, controller changes, RBAC changes, and webhook changes.
3. **Static Analysis** -- Applies rule-based detection for common breaking changes: field removals, required field additions, type changes, enum value removals, API version additions without conversion, validation rule tightening, default value changes, and condition type changes.
4. **LLM Analysis** -- Uses Claude to perform deep semantic analysis for subtle regressions: semantic changes, upgrade issues, performance concerns, edge cases, backward compatibility, and controller behavior changes.
5. **Report Generation** -- Creates a comprehensive markdown report (`output/regression-report.md`) with severity-ordered findings (Critical/High/Medium/Low), impact analysis, evidence, mitigation recommendations, and suggested test scenarios.

**Output:**
- `output/regression-report.md` -- Detailed regression risk report with executive summary, findings by severity, recommended actions, and test scenarios.

**Key Features:**
- Combines static analysis with LLM-powered semantic analysis
- Every finding includes specific mitigation steps and test scenarios
- Prioritizes findings by severity and real-world impact
- Framework-aware (controller-runtime vs library-go)
- Focuses on API versioning, upgrade paths, and backward compatibility

---

### `/oape:review`

Performs a "Principal Engineer" level code review that verifies code changes against Jira requirements.

**Usage:**
```shell
/oape:review OCPBUGS-12345
/oape:review OCPBUGS-12345 origin/release-4.15
```

**What it does:**
1. **Fetches Jira Issue** -- Retrieves the ticket details and acceptance criteria
2. **Analyzes Git Diff** -- Gets changes between base ref and HEAD
3. **Reviews Code** -- Applies four review modules:
   - **Golang Logic & Safety**: Intent matching, execution traces, edge cases, context usage, concurrency, error handling
   - **Bash Scripts**: Safety patterns, variable quoting, temp file handling
   - **Operator Metadata (OLM)**: RBAC updates, finalizer handling
   - **Build Consistency**: Generation drift detection
4. **Generates Report** -- Returns structured JSON with verdict, issues, and fix prompts
5. **Applies Fixes Automatically** -- When issues are found, invokes `implement-review-fixes.md` to apply the suggested code changes in severity order (CRITICAL first), then verifies the build still passes

---

### `/oape:e2e-generate`

Generates e2e test artifacts for any OpenShift operator repository by discovering the repo structure and analyzing the git diff from a base branch.

**Usage:**
```shell
# Generate e2e tests for changes since main
/oape:e2e-generate main

# Use a specific base branch and custom output directory
/oape:e2e-generate origin/release-4.18 --output .work
```

**What it does:**
1. **Prechecks** -- Validates the base branch argument, required tools (`git`, `go`), repository type (must be an OpenShift operator repo with controller-runtime or library-go), and verifies a non-empty git diff.
2. **Discovery** -- Detects framework (controller-runtime vs library-go), API types, CRDs, existing e2e test patterns, install mechanism (OLM or manual), operator namespace, and sample CRs.
3. **Diff Analysis** -- Categorizes changed files (API types, controllers, CRDs, RBAC, samples) and reads diff hunks to understand specific changes.
4. **Generation** -- Produces four files in `output/e2e_<repo-name>/`:
   - `test-cases.md` -- Test scenarios with context, prerequisites, install, CR deployment, diff-specific tests, verification, cleanup
   - `execution-steps.md` -- Step-by-step `oc` commands
   - `e2e_test.go` or `e2e_test.sh` -- Go (Ginkgo) or bash test code matching the repo's existing e2e pattern
   - `e2e-suggestions.md` -- Coverage recommendations

**Supports:**
- controller-runtime operators (Ginkgo e2e) -- e.g., cert-manager-operator, external-secrets-operator
- library-go operators (bash e2e) -- e.g., secrets-store-csi-driver-operator
- Operators with in-repo API types or external types from openshift/api

See [e2e-test-generator/](e2e-test-generator/) for fixture templates and pattern documentation.

## Prerequisites

- **go** -- Go toolchain
- **git** -- Git
- **gh** (GitHub CLI) -- installed and authenticated (for api-generate, api-implement, review)
- **make** -- Make (for api-implement)
- **curl** -- For fetching Jira issues (for review, analyze-rfe)
- **JIRA_PERSONAL_TOKEN** -- For analyze-rfe (Jira REST API)
- **oc** -- OpenShift CLI (recommended, for running generated execution steps)
- Must be run from within an OpenShift operator repository

## Conventions Enforced

- [OpenShift API Conventions](https://github.com/openshift/enhancements/blob/master/dev-guide/api-conventions.md)
- [Kubernetes API Conventions](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md)
- [Kubebuilder Controller Patterns](https://book.kubebuilder.io/cronjob-tutorial/controller-implementation)
- [Controller-Runtime Best Practices](https://pkg.go.dev/sigs.k8s.io/controller-runtime)
