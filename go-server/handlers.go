package main

import (
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
)

//go:embed static/homepage.html
var staticFS embed.FS

// App holds shared dependencies for HTTP handlers.
type App struct {
	cfg     *ServerConfig
	backend Backend
}

var epURLPattern = regexp.MustCompile(`^https://github\.com/openshift/enhancements/pull/\d+/?$`)
var jiraTicketPattern = regexp.MustCompile(`^[A-Z][A-Z0-9]+-\d+$`)

// CreateWorkflowRequest is the JSON body for POST /api/v1/workflows.
type CreateWorkflowRequest struct {
	EPUrl        string `json:"ep_url"`
	BaseBranch   string `json:"base_branch"`
	RepoURL      string `json:"repo_url"`
	JiraTicket   string `json:"jira_ticket"`
	JiraToken    string `json:"jira_token"`
	WorkflowMode string `json:"workflow_mode"`
}

// WorkflowSummary is a compact representation for workflow lists.
type WorkflowSummary struct {
	ID        string `json:"id"`
	Status    string `json:"status"`
	CreatedAt string `json:"createdAt"`
	RepoURL   string `json:"repoUrl"`
}

// WorkflowListResponse for GET /api/v1/workflows.
type WorkflowListResponse struct {
	Items []WorkflowSummary `json:"items"`
}

// RepoListResponse for GET /api/v1/repos.
type RepoListResponse struct {
	Items []RepoInfo `json:"items"`
}

// WorkflowDetailResponse for GET /api/v1/workflows/{job_id}.
type WorkflowDetailResponse struct {
	ID         string `json:"id"`
	Status     string `json:"status"`
	Message    string `json:"message,omitempty"`
	CreatedAt  string `json:"createdAt"`
	RepoURL    string `json:"repoUrl"`
	EPUrl      string `json:"epUrl,omitempty"`
	BaseBranch string `json:"baseBranch"`
	JiraTicket string `json:"jiraTicket,omitempty"`
}

// CreateWorkflowResponse for POST /api/v1/workflows.
type CreateWorkflowResponse struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

// fetchGHToken returns a GitHub token. If GH_TOKEN is set, it is used directly
// (local dev mode). Otherwise it requests a fresh GitHub App installation token
// from the ghpat HTTP sidecar service.
func fetchGHToken(serviceURL string) (token string, expiresAt string, err error) {
	if t := os.Getenv("GH_TOKEN"); t != "" {
		return t, "", nil
	}

	resp, err := http.Get(serviceURL + "/token")
	if err != nil {
		return "", "", fmt.Errorf("requesting token from ghpat service: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", "", fmt.Errorf("reading ghpat response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("ghpat service returned %d: %s", resp.StatusCode, body)
	}

	var result struct {
		Token     string `json:"token"`
		ExpiresAt string `json:"expires_at"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return "", "", fmt.Errorf("parsing ghpat response: %w", err)
	}
	if result.Token == "" {
		return "", "", fmt.Errorf("ghpat service returned empty token")
	}
	return result.Token, result.ExpiresAt, nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"detail": msg})
}

func generateJobID() (string, error) {
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// HandleHome serves the UI.
func (a *App) HandleHome(w http.ResponseWriter, r *http.Request) {
	data, err := staticFS.ReadFile("static/homepage.html")
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(data)
}

// HandleListRepos returns the list of allowed repositories.
func (a *App) HandleListRepos(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, RepoListResponse{
		Items: a.cfg.TeamRepos,
	})
}

// HandleCreateWorkflow starts a workflow run via the configured backend.
func (a *App) HandleCreateWorkflow(w http.ResponseWriter, r *http.Request) {
	var req CreateWorkflowRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	if req.RepoURL == "" || req.BaseBranch == "" {
		writeError(w, http.StatusBadRequest, "repo_url and base_branch are required")
		return
	}

	if req.EPUrl == "" && req.JiraTicket == "" {
		writeError(w, http.StatusBadRequest, "at least one of ep_url or jira_ticket is required")
		return
	}

	if req.EPUrl != "" && !epURLPattern.MatchString(req.EPUrl) {
		writeError(w, http.StatusBadRequest, "ep_url must be a valid OpenShift enhancement PR URL")
		return
	}

	if req.JiraTicket != "" && !jiraTicketPattern.MatchString(req.JiraTicket) {
		writeError(w, http.StatusBadRequest, "jira_ticket must be a valid Jira key (e.g. OCPBUGS-12345)")
		return
	}

	if req.WorkflowMode == "" {
		req.WorkflowMode = "full"
	}
	if req.WorkflowMode != "full" && req.WorkflowMode != "feature" && req.WorkflowMode != "bugfix" {
		writeError(w, http.StatusBadRequest, "workflow_mode must be one of: full, feature, bugfix")
		return
	}

	jobID, err := generateJobID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to generate job ID")
		return
	}

	ghToken, ghTokenExpiry, err := fetchGHToken(a.cfg.GHTokenServiceURL)
	if err != nil {
		log.Printf("ERROR: fetching GH token: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to fetch GitHub token")
		return
	}

	params := WorkflowParams{
		EPUrl:        req.EPUrl,
		RepoURL:      req.RepoURL,
		BaseBranch:   req.BaseBranch,
		GHToken:      ghToken,
		JiraTicket:   req.JiraTicket,
		JiraToken:    req.JiraToken,
		WorkflowMode: req.WorkflowMode,

		GHTokenExpiry:    ghTokenExpiry,
		GHTokenSecret:    "shift-gh-token-" + jobID,
		WorkerImage:      a.cfg.WorkerImage,
		EnvConfigMap:     a.cfg.WorkerEnvConfigMap,
		GCloudSecret:     a.cfg.GCloudSecretName,
		ConfigsConfigMap: a.cfg.ConfigsConfigMap,
		TTLAfterFinished: a.cfg.TTLAfterFinished,
	}

	if err := a.backend.StartWorkflow(r.Context(), jobID, params); err != nil {
		log.Printf("ERROR: creating workflow: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to create workflow")
		return
	}

	log.Printf("Created workflow %s for ep=%s jira=%s repo=%s base_branch=%s mode=%s",
		jobID, req.EPUrl, req.JiraTicket, req.RepoURL, req.BaseBranch, req.WorkflowMode)
	writeJSON(w, http.StatusCreated, CreateWorkflowResponse{
		ID:     jobID,
		Status: "pending",
	})
}

// HandleListWorkflows returns all workflow jobs.
func (a *App) HandleListWorkflows(w http.ResponseWriter, r *http.Request) {
	jobs, err := a.backend.ListWorkflows(r.Context())
	if err != nil {
		log.Printf("ERROR: listing workflows: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to list workflows")
		return
	}

	items := make([]WorkflowSummary, len(jobs))
	for i, j := range jobs {
		items[i] = WorkflowSummary{
			ID:        j.ID,
			Status:    j.Status,
			CreatedAt: j.CreatedAt,
			RepoURL:   j.RepoURL,
		}
	}

	writeJSON(w, http.StatusOK, WorkflowListResponse{Items: items})
}

// HandleGetWorkflow returns details of a specific workflow.
func (a *App) HandleGetWorkflow(w http.ResponseWriter, r *http.Request) {
	jobID := r.PathValue("job_id")
	if jobID == "" {
		writeError(w, http.StatusBadRequest, "job_id is required")
		return
	}

	info, err := a.backend.GetWorkflowInfo(r.Context(), jobID)
	if err != nil {
		writeError(w, http.StatusNotFound, fmt.Sprintf("workflow not found: %s", jobID))
		return
	}

	writeJSON(w, http.StatusOK, WorkflowDetailResponse{
		ID:         info.ID,
		Status:     info.Status,
		Message:    info.Message,
		CreatedAt:  info.CreatedAt,
		RepoURL:    info.RepoURL,
		EPUrl:      info.EPUrl,
		BaseBranch: info.BaseBranch,
		JiraTicket: info.JiraTicket,
	})
}

// HandleWorkflowLogs streams workflow logs as SSE events via the backend.
func (a *App) HandleWorkflowLogs(w http.ResponseWriter, r *http.Request) {
	jobID := r.PathValue("job_id")
	if jobID == "" {
		writeError(w, http.StatusBadRequest, "job_id is required")
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	if err := a.backend.StreamLogs(r.Context(), jobID, w, flusher); err != nil {
		log.Printf("ERROR: streaming logs for workflow %s: %v", jobID, err)
	}
}
