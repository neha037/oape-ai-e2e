---
description: Production-grade OpenShift code reviewer that validates logic, safety, OLM, and build consistency against Jira requirements
argument-hint: <ticket_id> [base_ref]
---

## Name
oape:review

## Synopsis
```shell
/oape:review <ticket_id> [base_ref]
```

## Description

The `oape:review` command performs a "Principal Engineer" level code review. It verifies that the code **actually solves the Jira problem** (Logic) and follows OpenShift safety standards.

The review covers five modules:
- **Golang Logic & Safety**: Intent matching, execution traces, edge cases, context usage, concurrency, error handling, scheme registration, namespace hardcoding, status handling, event recording
- **Bash Scripts**: Safety patterns, variable quoting, temp file handling
- **Operator Metadata (OLM)**: RBAC updates, RBAC three-way consistency, finalizer handling
- **Build Consistency**: Generation drift detection for types and CRDs, dependency completeness
- **Context-Adaptive Review**: Open-ended analysis tailored to the specific PR (owner references, proxy awareness, API deprecation, and other PR-specific concerns)

## Arguments

- `$1` (ticket_id): The Jira Ticket ID (e.g., OCPBUGS-12345). **Required.**
- `$2` (base_ref): The base git ref to diff against. Defaults to `origin/master`. **Optional.**


## Implementation

### Step 1: Determine Base Ref
- If `$2` (base_ref) is provided, use it
- If NOT provided, use `origin/master`

```bash
BASE_REF="${2:-origin/master}"

# Adjust for fork mode: if upstream remote exists, use it for the base ref
if git remote get-url upstream &>/dev/null 2>&1; then
  if [[ "$BASE_REF" == origin/* ]]; then
    BASE_REF="${BASE_REF/origin/upstream}"
    echo "Fork detected: adjusted base ref to $BASE_REF"
  fi
fi
```

### Step 2: Fetch Context
1. **Jira Issue**: Fetch the Jira issue details using curl:
   ```bash
   curl -s "https://issues.redhat.com/browse/$1"
   ```
   Focus on Acceptance Criteria as the primary validation source.

2. **Git Diff**: Get the code changes:
   ```bash
   git diff ${BASE_REF}...HEAD --stat -p
   ```

3. **File List**: Get list of changed files:
   ```bash
   git diff ${BASE_REF}...HEAD --name-only
   ```

### Step 3: Analyze Code Changes

Apply **all** of the following review criteria. Modules A–D are **mandatory** — every check must be evaluated on every review, regardless of PR size. Module E is an adaptive pass that extends the review based on what the PR actually does.

#### Module A: Golang (Logic & Safety)

**Logic Verification (The "Mental Sandbox")**:
- **Intent Match:** Does the code implementation match the Jira Acceptance Criteria? Quote the Jira line that justifies the change.
- **Execution Trace:** Mentally simulate the function.
    - *Happy Path:* Does it succeed as expected?
    - *Error Path:* If the API fails, does it retry or return an error?
- **Edge Cases:**
    - **Nil/Empty:** Does it handle `nil` pointers or empty slices?
    - **State:** Does it handle resources that are `Deleting` or `Pending`?

**Safety & Patterns**:
- **Context:** REJECT `context.TODO()` in production paths. Must use `context.WithTimeout`.
- **Concurrency:** `go func` must be tracked (WaitGroup/ErrGroup). No race conditions.
- **Errors:** Must use `fmt.Errorf("... %w", err)`. No capitalized error strings. Flag `_ =` assignments that discard error returns — in production code return the error, in test code use `t.Fatalf`.
- **Complexity:** Flag functions > 50 lines or > 3 nesting levels.

**Idiomatic Clean Code (via Golang-Skills):**
- **Slices/Maps:** Ensure slices are pre-allocated with `make` if the length is known. Avoid unnecessary `nil` slice vs. `empty` slice confusion.
- **Interfaces:** Reject "Interface Pollution" (defining interfaces before they are actually used by multiple implementations).
- **Naming:** Follow Go conventions (e.g., `url` not `URL` in mixed-case, `id` not `ID` for local vars, no `Get` prefix).
- **Receiver Types:** Check for consistency in pointer vs. value receivers.

**Scheme Registration** *(Severity: CRITICAL)*:
- For every `client.Get()`, `client.List()`, `client.Create()`, `client.Update()`, `client.Delete()` call in changed Go files, identify the GVK of the object being operated on.
- Read `main.go` or any file matching `*scheme*.go`. Look for `AddToScheme` or `SchemeBuilder.Register` calls.
- Every external type (not in the operator's own API group — e.g., `corev1`, `routev1`, `configv1`) used as a client call target **must** have a corresponding `AddToScheme` in scheme setup.
- Flag any external type used in client calls but missing from scheme registration.

**Sensitive Data in Logs** *(Severity: CRITICAL)*:
- For every `log.Info`, `log.V().Info`, `logger.Info`, `logger.Error`, `log.Error`, `klog.Infof`, `klog.V().Infof` call in changed Go files, examine each key-value parameter.
- Flag any parameter whose value contains or is derived from: cluster IDs (or suffixes/hashes of them), case IDs, secret data (`.data`, `.stringData` fields), SFTP credentials, upload paths containing case IDs, or directory names/file paths that embed cluster-identifying data.
- Operator logs are collected in must-gather bundles, forwarded to aggregation systems, and attached to support cases — any customer-identifying data in logs is a data leak.
- Safe alternatives: log boolean flags (`"hasClusterID", true`), counts (`"podCount", n`), resource kinds, durations, or error messages (with secrets scrubbed).
- Ignore test files (`*_test.go`).

**Namespace Hardcoding** *(Severity: WARNING)*:
- In changed Go files under `controllers/`, `pkg/controller/`, or any reconciler file, scan for string literals matching `"openshift-*"`, `"kube-*"`, or `"default"` used as namespace values.
- These should use constants, environment variables, or config/options structs.
- Ignore test files (`*_test.go`) and string literals inside comments or log messages.

**Status Handling (Infinite Requeue Prevention)** *(Severity: WARNING)*:
- In `Reconcile()` functions, flag patterns where a terminal/validation error causes `return ctrl.Result{}, err` (infinite requeue).
- Terminal failures (spec validation, type assertion, config parsing — NOT API call errors) should instead set a Degraded condition and return `ctrl.Result{}, nil`.

**Event Recording** *(Severity: INFO)*:
- Check if reconciler structs embed or reference a `record.EventRecorder`.
- If the reconciler performs significant state transitions (create, update, delete, degrade) without calling `recorder.Event()` or `recorder.Eventf()`, flag it.

#### Module B: Bash (Scripts)
- **Safety:** Must start with `set -euo pipefail`.
- **Quoting:** Variables in `oc`/`kubectl` commands MUST be quoted (`"$VAR"`).
- **Tmp Files:** Must use `mktemp`, never hardcoded paths like `/tmp/data`.

#### Module C: Operator Metadata (OLM)
- **RBAC:** If new K8s APIs are used in Go, check if `config/rbac/role.yaml` is updated.
- **RBAC Three-Way Consistency** *(Severity: CRITICAL)*:
    - Cross-reference three sources of RBAC truth and flag inconsistencies:
        1. **Kubebuilder markers**: `// +kubebuilder:rbac:groups=...,resources=...,verbs=...` in controller Go files.
        2. **ClusterRole manifest**: `config/rbac/role.yaml` (or `config/rbac/clusterrole.yaml`).
        3. **CSV permissions**: `bundle/manifests/*clusterserviceversion.yaml` — `spec.install.spec.clusterPermissions` and `spec.install.spec.permissions`.
    - All three must declare the same API groups, resources, and verbs.
    - Common drift: marker added but `role.yaml` not regenerated (missing `make manifests`); `role.yaml` updated but CSV not rebuilt (missing `make bundle`).
    - Also verify CSV is updated when API version, description, installModes, or new CRD entries change.
- **Finalizers:** If logic deletes resources, ensure Finalizers are handled to prevent hanging.

#### Module D: Build Consistency (The "Gotchas")
- **Generation Drift:**
    - IF `types.go` is modified, AND `zz_generated.deepcopy.go` is NOT in the file list -> **CRITICAL FAIL**.
    - IF `types.go` is modified, AND `config/crd/bases/...yaml` is NOT in the file list -> **CRITICAL FAIL**.
- **Dependency Completeness** *(Severity: WARNING)*:
    - If changed Go files introduce new import paths, verify they exist in `go.mod` (direct or indirect).
    - If a `vendor/` directory exists and `go.mod` is in the changed file list but `vendor/modules.txt` is not, flag that `go mod vendor` may need to be re-run.
    - Flag any import of a package that does not resolve to a module declared in `go.mod`.
- **Dead Test File Detection** *(Severity: WARNING)*:
    - For every new file in the diff (`git diff ${BASE_REF}...HEAD --name-only --diff-filter=A`), check if it is a test file (`.testsuite.yaml`, `_test.go`, or files under a `tests/` directory).
    - For `.testsuite.yaml` files: search the repo (excluding `vendor/`) for Go code that discovers and runs YAML test suites: `grep -rl "testsuite\.yaml\|TestSuite\|crdvalidationtest" --include="*.go"`. If no runner exists, flag: "Generated test file `<path>` is not connected to any test runner and will never be executed. Delete it or wire up a YAML test runner."
    - For `_test.go` files in non-standard directories (e.g., `output/`): verify the package is reachable by `go test ./...` — check that the directory is under a module path and not excluded by build tags or `.gitignore`. If unreachable, flag: "Test file `<path>` is in a directory not discovered by `go test ./...`."
    - Dead test files create a false sense of test coverage — they must be removed or connected to a runner.
- **CRD Manifest Consistency** *(Severity: CRITICAL)*:
    - Find all CRD YAML files across the repo: `grep -rl "kind: CustomResourceDefinition" --include="*.yaml" --include="*.yml"` (excluding `vendor/`, `testdata/`, `.git/`).
    - Group files by CRD name (`metadata.name` field in each file).
    - For each CRD name that appears in 2+ files, compare the `spec.versions[*].schema.openAPIV3Schema` and `spec.versions[*].additionalPrinterColumns` sections across all copies.
    - Any schema divergence → **CRITICAL**: "CRD manifest drift detected: `<file-a>` and `<file-b>` have different schemas for CRD `<crd-name>`. Run `make manifests` and sync all copies from the canonical source."
    - Common locations to check: `config/crd/bases/`, `deploy/crds/`, `bundle/manifests/`.
- **CEL Validation Rule Safety** *(Severity: CRITICAL)*:
    - For every `+kubebuilder:validation:XValidation` rule in changed files, verify that **all accesses to optional fields are guarded by `has()`** in the short-circuit chain. An optional field is one with `omitempty` in its JSON tag or a pointer type.
    - In Kubernetes CEL, accessing an absent optional field is a **runtime error**, not `false`. The `has()` function is an access precondition, not just a boolean predicate.
    - **CEL rules MUST use the conjunction (`&&`) form inside a negation, never the disjunction (`||`) form.** The `&&` operator reliably short-circuits in all Kubernetes CEL versions; the `||` form does not — certain K8s/OpenShift CEL engine versions evaluate all `||` terms eagerly, causing field accesses to run even when a preceding `has()` guard should have prevented it.
    - Mentally evaluate each CEL rule with every optional field **absent**. If any evaluation path reaches `self.X` without a preceding `has(self.X)` in the same `&&` chain → **CRITICAL FAIL**.
    - Common anti-pattern: applying De Morgan's law to convert `!(A && B)` into `!A || !B`. Even with `has()` guards present, the `||` form breaks in practice. Example:
      - Correct (`&&` form): `!(has(self.spec) && has(self.spec.field) && self.spec.field)`
      - Broken (`||` form, even with guards): `!has(self.spec) || !has(self.spec.field) || !self.spec.field` — crashes with `no such key` on certain K8s versions when `spec` exists but `field` is absent.
      - Fix: keep or rewrite to the `&&` form: `!(has(self.spec) && has(self.spec.field) && self.spec.field)`
- **Linter Compliance** *(Severity: WARNING)*:
    - Check if the repo has a `make lint` target: `make -n lint 2>/dev/null`.
    - If available, run `make lint` and report any findings as WARNING issues with the file, line, description, and a `fix_prompt` that describes how to resolve the linter error.
    - If `make lint` is not available, skip this check silently.
    - This catches issues that `go vet` misses: unchecked error returns, ineffectual assignments, security patterns, and other static analysis findings configured in the project's linter.
- **Required Field Propagation** *(Severity: CRITICAL)*:
    - For every field annotated with `+kubebuilder:validation:Required` in changed files, walk up the parent chain. If any ancestor struct field has `omitempty` in its JSON tag, the CRD schema will not enforce the `Required` marker because the ancestor itself is optional — the API server accepts a CR that omits the ancestor entirely.
    - Check: If a child field is `Required`, every ancestor struct field up to the root object MUST either (a) lack `omitempty` in its JSON tag, or (b) have its own `+kubebuilder:validation:Required` marker. Violation → **CRITICAL FAIL**.
    - Common case: `Spec` field on the root CR struct has `json:"spec,omitempty"` — this makes the entire spec optional, bypassing all required markers within it.

#### Module E: Context-Adaptive Review

After completing the mandatory checks above, perform an open-ended review pass tailored to this specific PR. Analyze what the code **actually does** and flag issues that the checklist does not cover. Focus areas to consider based on the PR content:

- **OwnerReferences / Garbage Collection:** If the PR creates child resources (Deployments, ConfigMaps, Services, etc.) via `client.Create()`, verify that `metav1.OwnerReference` is set so child resources are cleaned up when the parent CR is deleted. *(Severity: CRITICAL)*
- **Proxy / Disconnected Environment:** If the PR makes outbound HTTP calls (`http.Get`, `http.NewRequest`, `http.Client`), verify it respects `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` environment variables. OpenShift clusters behind proxies will fail silently without this. *(Severity: WARNING)*
- **API Deprecation:** If the PR imports API packages, check for deprecated versions (`v1beta1` when `v1` exists, `policy/v1beta1`, `extensions/v1beta1`). *(Severity: WARNING)*
- **Watch Predicates:** If the PR adds or modifies `Watches()`, `For()`, or `Owns()` calls, check if filtering predicates are used to avoid excessive reconciliation. *(Severity: INFO)*
- **Resource Requests/Limits:** If the PR creates Pod specs (Deployments, StatefulSets, Jobs), check if resource requests and limits are set. *(Severity: INFO)*
- **Leader Election Safety:** If the PR modifies cluster-scoped resources or runs background goroutines, verify leader election is configured to prevent split-brain in HA. *(Severity: WARNING)*

These are starting points, not an exhaustive list. Use your judgment as a principal engineer to flag any additional correctness, safety, or operational concern specific to this PR that is not covered by Modules A–D.

Report adaptive findings in the `issues` array using `"module": "Adaptive"` and the appropriate severity level.

### Step 4: Generate Report
Generate a structured JSON report based on the analysis.

### Step 5: Apply Fixes Automatically

After the report is generated, if the `issues` array is non-empty, automatically apply the suggested fixes by following the procedure in `implement-review-fixes.md`, passing the review report produced in Step 4 as input.

This step is skipped when the verdict is `"Approved"` and there are no issues.

## Return Value

Returns a JSON report with the following structure, followed by an automatic fix summary if issues were found:

```json
{
  "summary": {
    "verdict": "Approved | Changes Requested",
    "rating": "1-10",
    "simplicity_score": "1-10"
  },
  "logic_verification": {
    "jira_intent_met": true,
    "missing_edge_cases": ["List handled edge cases or gaps (e.g., 'Does not handle pod deletion')"]
  },
  "issues": [
    {
      "severity": "CRITICAL",
      "module": "Logic",
      "file": "pkg/controller/gather.go",
      "line": 45,
      "description": "Logic Error: Jira asks to 'retry on failure', but code returns 'nil' immediately.",
      "fix_prompt": "Update the error handling to use the retry logic..."
    },
    {
      "severity": "CRITICAL",
      "module": "Logic",
      "file": "pkg/controller/cert_controller.go",
      "line": 112,
      "description": "Scheme Registration: client.Get() targets routev1.Route but routev1.AddToScheme is not called in main.go.",
      "fix_prompt": "Add routev1.AddToScheme(scheme) to the scheme registration block in main.go..."
    },
    {
      "severity": "CRITICAL",
      "module": "OLM",
      "file": "controllers/mycontroller_controller.go",
      "line": 28,
      "description": "RBAC Consistency: kubebuilder marker grants 'get;list;watch' on 'routes' but config/rbac/role.yaml does not include this rule.",
      "fix_prompt": "Run 'make manifests' to regenerate RBAC from kubebuilder markers, then 'make bundle' to update CSV..."
    },
    {
      "severity": "WARNING",
      "module": "Adaptive",
      "file": "pkg/controller/cert_controller.go",
      "line": 87,
      "description": "Proxy Awareness: http.Get() call does not respect HTTP_PROXY/HTTPS_PROXY env vars. Will fail in disconnected clusters.",
      "fix_prompt": "Use net/http.ProxyFromEnvironment in the http.Transport to respect cluster proxy settings..."
    }
  ]
}
```

When issues are present, the fixes are applied automatically and a fix summary is appended (see `implement-review-fixes.md` for the summary format).

## Examples

1. **Review changes against origin/master**:
   ```shell
   /oape:review OCPBUGS-12345
   ```

2. **Review changes against a specific branch**:
   ```shell
   /oape:review OCPBUGS-12345 origin/release-4.15
   ```

3. **Review changes against a specific commit**:
   ```shell
   /oape:review OCPBUGS-12345 abc123def
   ```