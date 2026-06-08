package main

import (
	"encoding/csv"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// RepoInfo holds metadata about an allowed operator repository.
type RepoInfo struct {
	URL        string `json:"url"`
	Product    string `json:"product"`
	Role       string `json:"role"`
	BaseBranch string `json:"baseBranch,omitempty"`
}

// ServerConfig holds all configuration for the orchestrator.
type ServerConfig struct {
	ListenAddr    string
	ConfigDir     string
	ExecutionMode string // "local" or "k8s" (default: "local")
	TeamRepos     []RepoInfo

	// Local-mode fields.
	AgentScriptPath string // path to agent/main.py
	PythonBin       string // python binary name

	// K8s-mode fields (ignored in local mode).
	WorkerImage        string
	JobNamespace       string
	TTLAfterFinished   int32
	WorkerEnvConfigMap string
	GCloudSecretName   string
	GHTokenServiceURL  string
	ConfigsConfigMap   string
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// LoadConfig reads configuration from environment variables and team-repos.csv.
func LoadConfig() (*ServerConfig, error) {
	configDir := envOrDefault("CONFIG_DIR", "/config")

	ttl := int32(5400) // 1h30m
	if v := os.Getenv("TTL_AFTER_FINISHED"); v != "" {
		n, err := strconv.ParseInt(v, 10, 32)
		if err != nil {
			return nil, fmt.Errorf("invalid TTL_AFTER_FINISHED: %w", err)
		}
		ttl = int32(n)
	}

	namespace := os.Getenv("JOB_NAMESPACE")
	if namespace == "" {
		data, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace")
		if err == nil {
			namespace = strings.TrimSpace(string(data))
		} else {
			namespace = "default"
		}
	}

	repos, err := loadTeamRepos(filepath.Join(configDir, "team-repos.csv"))
	if err != nil {
		return nil, fmt.Errorf("loading team repos: %w", err)
	}

	return &ServerConfig{
		ListenAddr:    envOrDefault("LISTEN_ADDR", ":8080"),
		ConfigDir:     configDir,
		ExecutionMode: envOrDefault("EXECUTION_MODE", "local"),
		TeamRepos:     repos,

		AgentScriptPath: envOrDefault("AGENT_SCRIPT_PATH", "../agent/main.py"),
		PythonBin:       envOrDefault("PYTHON_BIN", "python3.11"),

		WorkerImage:        envOrDefault("WORKER_IMAGE", "quay.io/openshift-oap/ai-agent:latest"),
		JobNamespace:       namespace,
		TTLAfterFinished:   ttl,
		WorkerEnvConfigMap: envOrDefault("WORKER_ENV_CONFIGMAP", "shift-worker-config"),
		GCloudSecretName:   envOrDefault("GCLOUD_SECRET_NAME", "gcloud-adc"),
		GHTokenServiceURL:  envOrDefault("GH_TOKEN_SERVICE_URL", "http://localhost:8081"),
		ConfigsConfigMap:   envOrDefault("CONFIGS_CONFIGMAP", "shift-worker-config"),
	}, nil
}

// loadTeamRepos parses team-repos.csv into a slice of RepoInfo.
// Supports both 3-column (product,role,repo_url) and 4-column
// (product,role,repo_url,base_branch) formats for backward compatibility.
func loadTeamRepos(csvPath string) ([]RepoInfo, error) {
	f, err := os.Open(csvPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	reader := csv.NewReader(f)
	reader.FieldsPerRecord = -1 // allow variable column count
	records, err := reader.ReadAll()
	if err != nil {
		return nil, err
	}

	if len(records) < 2 {
		return nil, fmt.Errorf("team-repos.csv has no data rows")
	}

	var repos []RepoInfo
	for _, row := range records[1:] {
		if len(row) < 3 {
			continue
		}
		product := strings.TrimSpace(row[0])
		role := strings.TrimSpace(row[1])
		repoURL := strings.TrimSuffix(strings.TrimSpace(row[2]), ".git")

		if repoURL == "" {
			continue
		}

		baseBranch := ""
		if len(row) >= 4 {
			baseBranch = strings.TrimSpace(row[3])
		}

		repos = append(repos, RepoInfo{
			URL:        repoURL,
			Product:    product,
			Role:       role,
			BaseBranch: baseBranch,
		})
	}

	return repos, nil
}
