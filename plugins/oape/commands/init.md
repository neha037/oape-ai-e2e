---
description: Clone an allowed OpenShift operator repository by short name into the current directory
argument-hint: <repo-short-name>
---

## Name
oape:init

## Synopsis
```shell
/oape:init <repo-short-name>
```

## Description
The `oape:init` command clones an allowed OpenShift operator repository into the current working directory using a short repository name. It uses `git clone --filter=blob:none` for efficient blobless cloning, then changes into the cloned directory so that subsequent `/oape:*` commands work immediately.

The short name is matched case-insensitively against the allowlist of team repositories. Partial matches are supported: if the input uniquely matches one repository it is used automatically; if it matches multiple, all matches are displayed and the user is asked to be more specific.

**You MUST follow ALL steps strictly. If any precheck fails, you MUST stop immediately and report the failure.**

## Implementation

### Phase 0: Prechecks

All prechecks must pass before proceeding. If ANY precheck fails, STOP immediately and report the failure.

#### Precheck 1 — Validate Argument

The provided argument MUST be a non-empty repository short name.

```bash
REPO_SHORT_NAME="$ARGUMENTS"

if [ -z "$REPO_SHORT_NAME" ]; then
  echo "PRECHECK FAILED: No repository short name provided."
  echo "Usage: /oape:init <repo-short-name>"
  echo ""
  echo "Available repositories:"
  echo "  cert-manager-operator      -- openshift/cert-manager-operator"
  echo "  jetstack-cert-manager      -- openshift/jetstack-cert-manager"
  echo "  cert-manager-istio-csr     -- openshift/cert-manager-istio-csr"
  echo "  external-secrets-operator  -- openshift/external-secrets-operator"
  echo "  external-secrets           -- openshift/external-secrets"
  exit 1
fi

echo "Repository short name: $REPO_SHORT_NAME"
```

#### Precheck 2 — Verify Required Tools

```bash
MISSING_TOOLS=""

# Check git
if ! command -v git &> /dev/null; then
  MISSING_TOOLS="$MISSING_TOOLS git"
fi

# Check gh CLI
if ! command -v gh &> /dev/null; then
  MISSING_TOOLS="$MISSING_TOOLS gh(GitHub CLI)"
fi

if [ -n "$MISSING_TOOLS" ]; then
  echo "PRECHECK FAILED: Missing required tools:$MISSING_TOOLS"
  echo "Please install the missing tools and try again."
  exit 1
fi

echo "Required tools are available."
```

#### Precheck 3 — Verify GitHub CLI Authentication

```bash
if ! gh auth status &> /dev/null 2>&1; then
  echo "PRECHECK FAILED: GitHub CLI is not authenticated."
  echo "Run 'gh auth login' to authenticate."
  exit 1
fi

echo "GitHub CLI is authenticated."
```

**If ALL prechecks above passed, proceed to Phase 1.**
**If ANY precheck FAILED (exit 1), STOP. Do NOT proceed further. Report the failure to the user.**

---

### Phase 1: Resolve Repository

Match the user-provided short name against the hardcoded allowlist. The allowlist is derived from `team-repos.txt`.

```thinking
I must match the user-provided short name against the allowlist. The allowlist is:

  cert-manager-operator     -> https://github.com/openshift/cert-manager-operator
  jetstack-cert-manager     -> https://github.com/openshift/jetstack-cert-manager
  cert-manager-istio-csr    -> https://github.com/openshift/cert-manager-istio-csr
  external-secrets-operator -> https://github.com/openshift/external-secrets-operator
  external-secrets          -> https://github.com/openshift/external-secrets
  ztiwm-operator            -> https://github.com/openshift/zero-trust-workload-identity-manager
  ztiwm-spire               -> https://github.com/openshift/spiffe-spire

Matching rules (applied in order):
1. Exact match (case-insensitive): if the lowercased input exactly equals a short name, use it.
2. Partial match: if the lowercased input is a substring of one or more short names:
   a. If exactly one match, use it.
   b. If multiple matches, list them all and ask the user to choose.
3. No match: list all available short names and STOP.
```

```bash
# Allowlist: short-name -> clone URL
declare -A REPO_MAP
REPO_MAP["cert-manager-operator"]="https://github.com/openshift/cert-manager-operator"
REPO_MAP["jetstack-cert-manager"]="https://github.com/openshift/jetstack-cert-manager"
REPO_MAP["cert-manager-istio-csr"]="https://github.com/openshift/cert-manager-istio-csr"
REPO_MAP["external-secrets-operator"]="https://github.com/openshift/external-secrets-operator"
REPO_MAP["external-secrets"]="https://github.com/openshift/external-secrets"
REPO_MAP["ztiwm-operator"]="https://github.com/openshift/zero-trust-workload-identity-manager"
REPO_MAP["ztiwm-spire"]="https://github.com/openshift/spiffe-spire"

INPUT=$(echo "$REPO_SHORT_NAME" | tr '[:upper:]' '[:lower:]')

# Exact match first
if [ -n "${REPO_MAP[$INPUT]+x}" ]; then
  CLONE_URL="${REPO_MAP[$INPUT]}"
  MATCHED_NAME="$INPUT"
  echo "Exact match: $MATCHED_NAME -> $CLONE_URL"
else
  # Partial/substring match
  MATCHES=()
  for key in "${!REPO_MAP[@]}"; do
    if [[ "$key" == *"$INPUT"* ]]; then
      MATCHES+=("$key")
    fi
  done

  if [ ${#MATCHES[@]} -eq 0 ]; then
    echo "FAILED: No repository matches '$REPO_SHORT_NAME'."
    echo ""
    echo "Available repositories:"
    for key in "${!REPO_MAP[@]}"; do
      echo "  $key -> ${REPO_MAP[$key]}"
    done
    exit 1
  elif [ ${#MATCHES[@]} -eq 1 ]; then
    MATCHED_NAME="${MATCHES[0]}"
    CLONE_URL="${REPO_MAP[$MATCHED_NAME]}"
    echo "Partial match: $MATCHED_NAME -> $CLONE_URL"
  else
    echo "FAILED: Ambiguous short name '$REPO_SHORT_NAME' matches multiple repositories:"
    echo ""
    for match in "${MATCHES[@]}"; do
      echo "  $match -> ${REPO_MAP[$match]}"
    done
    echo ""
    echo "Please provide a more specific name."
    exit 1
  fi
fi

echo "Resolved: $MATCHED_NAME -> $CLONE_URL"
```

---

### Phase 2: Clone Repository

Clone the resolved repository into the current working directory using `git clone --filter=blob:none`. Handle the case where the target directory already exists.

```bash
CLONE_DIR="$MATCHED_NAME"

if [ -d "$CLONE_DIR" ]; then
  echo "Directory '$CLONE_DIR' already exists."

  # Check if it is a git repo pointing to the same remote
  EXISTING_REMOTE=$(git -C "$CLONE_DIR" remote get-url origin 2>/dev/null || true)

  if [ -n "$EXISTING_REMOTE" ]; then
    # Normalize URLs for comparison (strip trailing slashes and .git suffix)
    NORM_EXISTING=$(echo "$EXISTING_REMOTE" | sed 's/\.git$//' | sed 's:/$::')
    NORM_CLONE=$(echo "$CLONE_URL" | sed 's/\.git$//' | sed 's:/$::')

    if [ "$NORM_EXISTING" = "$NORM_CLONE" ]; then
      echo "Existing directory is already a clone of the same repository."
      echo "Using existing directory as-is."
    else
      echo "FAILED: Directory '$CLONE_DIR' exists but points to a different remote."
      echo "  Expected: $CLONE_URL"
      echo "  Found:    $EXISTING_REMOTE"
      echo ""
      echo "Options:"
      echo "  1. Remove the directory manually: rm -rf $CLONE_DIR"
      echo "  2. Use a different working directory"
      exit 1
    fi
  else
    echo "FAILED: Directory '$CLONE_DIR' exists but is not a git repository."
    echo ""
    echo "Options:"
    echo "  1. Remove the directory manually: rm -rf $CLONE_DIR"
    echo "  2. Use a different working directory"
    exit 1
  fi
else
  echo "Cloning $CLONE_URL into $CLONE_DIR..."
  git clone --filter=blob:none "$CLONE_URL"

  if [ $? -ne 0 ]; then
    echo "FAILED: git clone failed."
    echo "Check your network connection and repository access."
    exit 1
  fi

  echo "Clone complete."
fi
```

---

### Phase 3: Change Directory and Verify

Change into the cloned repository directory and verify it is a valid Go-based operator repository.

```bash
cd "$CLONE_DIR" || { echo "FAILED: Cannot change to directory $CLONE_DIR"; exit 1; }

# Verify Go module
if [ -f "go.mod" ]; then
  GO_MODULE=$(head -1 go.mod | awk '{print $2}')
  echo "Go module: $GO_MODULE"
else
  echo "WARNING: No go.mod found. This may not be a Go-based operator repository."
  GO_MODULE="(not detected)"
fi

# Detect operator framework
FRAMEWORK="unknown"
if [ -f "go.mod" ]; then
  if grep -q "sigs.k8s.io/controller-runtime" go.mod 2>/dev/null; then
    FRAMEWORK="controller-runtime"
  elif grep -q "github.com/openshift/library-go" go.mod 2>/dev/null; then
    FRAMEWORK="library-go"
  fi
fi

echo "Framework: $FRAMEWORK"
echo "Current directory: $(pwd)"
```

---

### Phase 4: Output Summary

```text
=== Repository Init Summary ===

Repository:  <matched-name>
Clone URL:   <clone-url>
Local Path:  <absolute-path-to-cloned-dir>
Go Module:   <module-name>
Framework:   <controller-runtime | library-go | unknown>

Next Steps:
  1. Generate API types:       /oape:api-generate <enhancement-pr-url>
  2. Generate API tests:       /oape:api-generate-tests <path-to-types>
  3. Generate controller code: /oape:api-implement <enhancement-pr-url>
```

---

## Critical Failure Conditions

The command MUST FAIL and STOP immediately if ANY of the following are true:

1. **No argument provided**: No repository short name was given
2. **Missing tools**: `git` or `gh` are not installed, or `gh` is not authenticated
3. **No match**: The short name does not match any allowed repository
4. **Ambiguous match**: The short name matches multiple repositories (show them all)
5. **Clone failed**: The git clone command fails (network, permissions, etc.)
6. **Directory conflict**: The target directory exists but is not a clone of the expected repository

When failing, provide a clear error message explaining:
- Which check failed
- What the expected state is
- How to fix the issue

## Behavioral Rules

1. **Allowlist only**: Only clone repositories from the hardcoded allowlist. Never clone arbitrary URLs.
2. **Efficient cloning**: Always use `git clone --filter=blob:none` for blobless clones.
3. **Non-destructive**: Never delete an existing directory automatically. If a directory conflict exists, report it and let the user decide.
4. **Case-insensitive matching**: Short name matching is case-insensitive.
5. **Partial match disambiguation**: If a partial match hits multiple repos, list them all and ask the user to be more specific rather than guessing.
6. **Idempotent**: If the directory already exists and is a clone of the correct repository, use it as-is without re-cloning.

## Arguments

- `<repo-short-name>`: The short name of the repository to clone
  - Required argument
  - Case-insensitive
  - Supports partial matching with disambiguation
  - Valid short names:
    - `cert-manager-operator` -- openshift/cert-manager-operator
    - `jetstack-cert-manager` -- openshift/jetstack-cert-manager
    - `cert-manager-istio-csr` -- openshift/cert-manager-istio-csr
    - `external-secrets-operator` -- openshift/external-secrets-operator
    - `external-secrets` -- openshift/external-secrets

## Prerequisites

- **git** -- Git installed
- **gh** (GitHub CLI) -- installed and authenticated (`gh auth login`)
- Access to the `openshift` GitHub organization repositories
