package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// ProcessBackend runs agent workflows as local subprocesses.
type ProcessBackend struct {
	pythonBin  string
	scriptPath string
	workflows  sync.Map // map[string]*localWorkflow
}

type localWorkflow struct {
	mu         sync.Mutex
	id         string
	status     string // pending, running, succeeded, failed
	epURL      string
	repoURL    string
	baseBranch string
	jiraTicket string
	createdAt  time.Time
	errorMsg   string

	logs      []string
	listeners []chan string
	done      chan struct{} // closed when process exits
}

// NewProcessBackend creates a backend that spawns local subprocesses.
func NewProcessBackend(pythonBin, scriptPath string) *ProcessBackend {
	return &ProcessBackend{
		pythonBin:  pythonBin,
		scriptPath: scriptPath,
	}
}

func (pb *ProcessBackend) StartWorkflow(_ context.Context, id string, params WorkflowParams) error {
	wf := &localWorkflow{
		id:         id,
		status:     "running",
		epURL:      params.EPUrl,
		repoURL:    params.RepoURL,
		baseBranch: params.BaseBranch,
		jiraTicket: params.JiraTicket,
		createdAt:  time.Now().UTC(),
		done:       make(chan struct{}),
	}
	pb.workflows.Store(id, wf)

	cmd := exec.Command(pb.pythonBin, pb.scriptPath)
	env := append(os.Environ(),
		"EP_URL="+params.EPUrl,
		"REPO_URL="+params.RepoURL,
		"BASE_BRANCH="+params.BaseBranch,
		"GH_TOKEN="+params.GHToken,
		"PYTHONUNBUFFERED=1",
	)
	if params.JiraTicket != "" {
		env = append(env, "JIRA_TICKET="+params.JiraTicket)
	}
	if params.JiraToken != "" {
		env = append(env, "JIRA_PERSONAL_TOKEN="+params.JiraToken)
	}
	if params.WorkflowMode != "" {
		env = append(env, "WORKFLOW_MODE="+params.WorkflowMode)
	}
	cmd.Env = env

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("creating stdout pipe: %w", err)
	}
	cmd.Stderr = cmd.Stdout // merge stderr into stdout

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("starting agent process: %w", err)
	}

	log.Printf("Started local workflow %s (pid=%d)", id, cmd.Process.Pid)

	go func() {
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			wf.appendLog(line)
		}

		exitErr := cmd.Wait()

		wf.mu.Lock()
		if exitErr != nil {
			wf.status = "failed"
			wf.errorMsg = findFailureMessage(wf.logs, exitErr)
		} else {
			wf.status = "succeeded"
		}
		// Close all listener channels and the done channel.
		for _, ch := range wf.listeners {
			close(ch)
		}
		wf.listeners = nil
		close(wf.done)
		wf.mu.Unlock()

		log.Printf("Workflow %s finished: status=%s", id, wf.status)
	}()

	return nil
}

// findFailureMessage extracts the most useful error from logs or the exit error.
func findFailureMessage(logs []string, exitErr error) string {
	for i := len(logs) - 1; i >= 0; i-- {
		if strings.HasPrefix(logs[i], "WORKFLOW_FAILED:") {
			return strings.TrimSpace(strings.TrimPrefix(logs[i], "WORKFLOW_FAILED:"))
		}
	}
	if exitErr != nil {
		return exitErr.Error()
	}
	return "unknown error"
}

func (wf *localWorkflow) appendLog(line string) {
	wf.mu.Lock()
	defer wf.mu.Unlock()
	wf.logs = append(wf.logs, line)
	for _, ch := range wf.listeners {
		select {
		case ch <- line:
		default:
			// Drop if listener is full (shouldn't happen with buffered channels).
		}
	}
}

// subscribe returns buffered logs and a channel for new lines.
// The channel is closed when the workflow finishes.
func (wf *localWorkflow) subscribe() ([]string, chan string) {
	wf.mu.Lock()
	defer wf.mu.Unlock()

	snapshot := make([]string, len(wf.logs))
	copy(snapshot, wf.logs)

	ch := make(chan string, 256)
	if wf.status == "succeeded" || wf.status == "failed" {
		close(ch)
		return snapshot, ch
	}

	wf.listeners = append(wf.listeners, ch)
	return snapshot, ch
}

func (pb *ProcessBackend) getWorkflow(id string) (*localWorkflow, error) {
	val, ok := pb.workflows.Load(id)
	if !ok {
		return nil, fmt.Errorf("workflow not found: %s", id)
	}
	return val.(*localWorkflow), nil
}

func (pb *ProcessBackend) GetWorkflowStatus(_ context.Context, id string) (*JobStatus, error) {
	wf, err := pb.getWorkflow(id)
	if err != nil {
		return nil, err
	}
	wf.mu.Lock()
	defer wf.mu.Unlock()
	return &JobStatus{Status: wf.status, Message: wf.errorMsg}, nil
}

func (pb *ProcessBackend) GetWorkflowInfo(_ context.Context, id string) (*JobInfo, error) {
	wf, err := pb.getWorkflow(id)
	if err != nil {
		return nil, err
	}
	wf.mu.Lock()
	defer wf.mu.Unlock()
	return &JobInfo{
		ID:         wf.id,
		Status:     wf.status,
		Message:    wf.errorMsg,
		CreatedAt:  wf.createdAt.Format("2006-01-02T15:04:05Z"),
		RepoURL:    wf.repoURL,
		EPUrl:      wf.epURL,
		BaseBranch: wf.baseBranch,
		JiraTicket: wf.jiraTicket,
	}, nil
}

func (pb *ProcessBackend) ListWorkflows(_ context.Context) ([]JobInfo, error) {
	var result []JobInfo
	pb.workflows.Range(func(_, value any) bool {
		wf := value.(*localWorkflow)
		wf.mu.Lock()
		result = append(result, JobInfo{
			ID:         wf.id,
			Status:     wf.status,
			Message:    wf.errorMsg,
			CreatedAt:  wf.createdAt.Format("2006-01-02T15:04:05Z"),
			RepoURL:    wf.repoURL,
			EPUrl:      wf.epURL,
			BaseBranch: wf.baseBranch,
			JiraTicket: wf.jiraTicket,
		})
		wf.mu.Unlock()
		return true
	})
	return result, nil
}

func (pb *ProcessBackend) StreamLogs(ctx context.Context, id string, w http.ResponseWriter, flusher http.Flusher) error {
	wf, err := pb.getWorkflow(id)
	if err != nil {
		return err
	}

	buffered, ch := wf.subscribe()

	// Emit initial status.
	fmt.Fprintf(w, "event: status\ndata: %s\n\n", `{"status":"running"}`)
	flusher.Flush()

	// Send buffered log lines.
	for _, line := range buffered {
		fmt.Fprintf(w, "event: log\ndata: %s\n\n", escapeSSE(line))
		flusher.Flush()
	}

	// Stream new lines until done or client disconnects.
	for {
		select {
		case <-ctx.Done():
			return nil
		case line, ok := <-ch:
			if !ok {
				// Channel closed: workflow finished.
				status, _ := pb.GetWorkflowStatus(ctx, id)
				if status == nil {
					status = &JobStatus{Status: "unknown", Message: "could not determine final status"}
				}
				data, _ := json.Marshal(status)
				fmt.Fprintf(w, "event: complete\ndata: %s\n\n", data)
				flusher.Flush()
				return nil
			}
			fmt.Fprintf(w, "event: log\ndata: %s\n\n", escapeSSE(line))
			flusher.Flush()
		}
	}
}

// escapeSSE ensures multi-line strings are valid SSE data fields.
func escapeSSE(line string) string {
	return strings.ReplaceAll(line, "\n", "\ndata: ")
}
