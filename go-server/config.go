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
	URL     string `json:"url"`
	Product string `json:"product"`
	Role    string `json:"role"`
}

// ServerConfig holds all configuration for the orchestrator.
type ServerConfig struct {
	WorkerImage        string
	JobNamespace       string
	TTLAfterFinished   int32
	ListenAddr         string
	ConfigDir          string
	WorkerEnvConfigMap string
	GCloudSecretName   string
	GHTokenServiceURL  string
	ConfigsConfigMap   string
	TeamRepos          []RepoInfo
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
		// Read from in-cluster service account.
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
		WorkerImage:        envOrDefault("WORKER_IMAGE", "ghcr.io/openshift-eng/oape-ai-e2e:latest"),
		JobNamespace:       namespace,
		TTLAfterFinished:   ttl,
		ListenAddr:         envOrDefault("LISTEN_ADDR", ":8080"),
		ConfigDir:          configDir,
		WorkerEnvConfigMap: envOrDefault("WORKER_ENV_CONFIGMAP", "shift-worker-config"),
		GCloudSecretName:   envOrDefault("GCLOUD_SECRET_NAME", "gcloud-adc"),
		GHTokenServiceURL:  envOrDefault("GH_TOKEN_SERVICE_URL", "http://localhost:8081"),
		ConfigsConfigMap:   envOrDefault("CONFIGS_CONFIGMAP", "shift-worker-config"),
		TeamRepos:          repos,
	}, nil
}

// loadTeamRepos parses team-repos.csv into a slice of RepoInfo.
func loadTeamRepos(csvPath string) ([]RepoInfo, error) {
	f, err := os.Open(csvPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	reader := csv.NewReader(f)
	records, err := reader.ReadAll()
	if err != nil {
		return nil, err
	}

	if len(records) < 2 {
		return nil, fmt.Errorf("team-repos.csv has no data rows")
	}

	var repos []RepoInfo
	// Skip header row.
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

		repos = append(repos, RepoInfo{
			URL:     repoURL,
			Product: product,
			Role:    role,
		})
	}

	return repos, nil
}
