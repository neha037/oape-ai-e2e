package main

import (
	"context"
	"net/http"
)

// Backend abstracts workflow execution so that both local subprocess
// and Kubernetes Job backends can be used interchangeably.
type Backend interface {
	// StartWorkflow launches a new workflow run. The id is pre-generated.
	StartWorkflow(ctx context.Context, id string, params WorkflowParams) error

	// GetWorkflowStatus returns the current status of a workflow.
	GetWorkflowStatus(ctx context.Context, id string) (*JobStatus, error)

	// GetWorkflowInfo returns extended metadata for a workflow.
	GetWorkflowInfo(ctx context.Context, id string) (*JobInfo, error)

	// ListWorkflows returns all known workflows.
	ListWorkflows(ctx context.Context) ([]JobInfo, error)

	// StreamLogs writes SSE events (status, log, complete) to the
	// ResponseWriter until the workflow finishes or the context is cancelled.
	StreamLogs(ctx context.Context, id string, w http.ResponseWriter, flusher http.Flusher) error
}

// WorkflowParams holds the parameters needed to start a workflow,
// used by both local and K8s backends.
type WorkflowParams struct {
	EPUrl      string
	RepoURL    string
	BaseBranch string
	GHToken    string

	// Optional Jira ticket ID (e.g. OCPBUGS-12345) used as primary or
	// supplementary input for the workflow.
	JiraTicket string
	JiraToken  string

	// WorkflowMode controls PR splitting: "full" (3 PRs), "feature" (2 PRs),
	// or "bugfix" (1 PR). Defaults to "full".
	WorkflowMode string

	// K8s-only fields (ignored by the local backend).
	GHTokenExpiry    string
	GHTokenSecret    string
	WorkerImage      string
	EnvConfigMap     string
	GCloudSecret     string
	ConfigsConfigMap string
	TTLAfterFinished int32
}

// JobStatus represents the current state of a workflow.
type JobStatus struct {
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
}

// JobInfo contains extended workflow information.
type JobInfo struct {
	ID         string
	Status     string
	Message    string
	CreatedAt  string
	RepoURL    string
	EPUrl      string
	BaseBranch string
	JiraTicket string
}
