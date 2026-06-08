package main

import (
	"log"
	"net/http"
)

func main() {
	cfg, err := LoadConfig()
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	var backend Backend
	switch cfg.ExecutionMode {
	case "k8s":
		k8s, err := NewK8sBackend(cfg.JobNamespace)
		if err != nil {
			log.Fatalf("failed to create k8s client: %v", err)
		}
		backend = k8s
		log.Printf("Using K8s backend (namespace=%s)", cfg.JobNamespace)
	default:
		backend = NewProcessBackend(cfg.PythonBin, cfg.AgentScriptPath)
		log.Printf("Using local subprocess backend (python=%s, script=%s)",
			cfg.PythonBin, cfg.AgentScriptPath)
	}

	app := &App{
		cfg:     cfg,
		backend: backend,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", app.HandleHome)
	mux.HandleFunc("GET /api/v1/repos", app.HandleListRepos)
	mux.HandleFunc("GET /api/v1/workflows", app.HandleListWorkflows)
	mux.HandleFunc("GET /api/v1/workflows/{job_id}", app.HandleGetWorkflow)
	mux.HandleFunc("POST /api/v1/workflows", app.HandleCreateWorkflow)
	mux.HandleFunc("GET /api/v1/workflows/{job_id}/log", app.HandleWorkflowLogs)

	log.Printf("OAPE server ready at http://localhost%s", cfg.ListenAddr)
	log.Fatal(http.ListenAndServe(cfg.ListenAddr, mux))
}
