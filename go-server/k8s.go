package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// K8sBackend runs agent workflows as Kubernetes Jobs.
type K8sBackend struct {
	clientset kubernetes.Interface
	namespace string
}

// NewK8sBackend creates a Kubernetes client using in-cluster config,
// falling back to KUBECONFIG for local development.
func NewK8sBackend(namespace string) (*K8sBackend, error) {
	config, err := rest.InClusterConfig()
	if err != nil {
		config, err = clientcmd.BuildConfigFromFlags("", clientcmd.RecommendedHomeFile)
		if err != nil {
			return nil, fmt.Errorf("building k8s config: %w", err)
		}
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("creating k8s clientset: %w", err)
	}

	return &K8sBackend{clientset: clientset, namespace: namespace}, nil
}

func (c *K8sBackend) StartWorkflow(ctx context.Context, jobID string, params WorkflowParams) error {
	jobName := "shift-workflow-" + jobID
	secretName := params.GHTokenSecret

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name: secretName,
			Labels: map[string]string{
				"app":    "shift-worker",
				"job-id": jobID,
			},
			Annotations: map[string]string{
				"app-platform-shift.openshift.github.io/gh-app-token-expiry": params.GHTokenExpiry,
			},
		},
		StringData: map[string]string{
			"GH_TOKEN":            params.GHToken,
			"JIRA_PERSONAL_TOKEN": params.JiraToken,
		},
	}
	if _, err := c.clientset.CoreV1().Secrets(c.namespace).Create(ctx, secret, metav1.CreateOptions{}); err != nil {
		return fmt.Errorf("creating secret %s: %w", secretName, err)
	}

	backoffLimit := int32(0)
	ttl := params.TTLAfterFinished

	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name: jobName,
			Labels: map[string]string{
				"app":    "shift-worker",
				"job-id": jobID,
			},
			Annotations: map[string]string{
				"app-platform-shift.openshift.github.io/repo-url":    params.RepoURL,
				"app-platform-shift.openshift.github.io/ep-url":      params.EPUrl,
				"app-platform-shift.openshift.github.io/base-branch": params.BaseBranch,
				"app-platform-shift.openshift.github.io/jira-ticket": params.JiraTicket,
			},
		},
		Spec: batchv1.JobSpec{
			BackoffLimit:            &backoffLimit,
			TTLSecondsAfterFinished: &ttl,
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{
						"app":    "shift-worker",
						"job-id": jobID,
					},
				},
				Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					Containers: []corev1.Container{
						{
							Name:    "worker",
							Image:   params.WorkerImage,
							Command: []string{"sh", "-c", "python3.11 /app/main.py"},
							Env: []corev1.EnvVar{
								{Name: "EP_URL", Value: params.EPUrl},
								{Name: "REPO_URL", Value: params.RepoURL},
								{Name: "BASE_BRANCH", Value: params.BaseBranch},
								{Name: "JIRA_TICKET", Value: params.JiraTicket},
								{Name: "WORKFLOW_MODE", Value: params.WorkflowMode},
								{Name: "PYTHONUNBUFFERED", Value: "1"},
								{Name: "GOOGLE_APPLICATION_CREDENTIALS", Value: "/secrets/gcloud/application_default_credentials.json"},
							},
							EnvFrom: []corev1.EnvFromSource{
								{
									ConfigMapRef: &corev1.ConfigMapEnvSource{
										LocalObjectReference: corev1.LocalObjectReference{
											Name: params.EnvConfigMap,
										},
									},
								},
								{
									SecretRef: &corev1.SecretEnvSource{
										LocalObjectReference: corev1.LocalObjectReference{
											Name: secretName,
										},
									},
								},
							},
							Resources: corev1.ResourceRequirements{
								Requests: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse("500m"),
									corev1.ResourceMemory: resource.MustParse("512Mi"),
								},
								Limits: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse("2"),
									corev1.ResourceMemory: resource.MustParse("4Gi"),
								},
							},
							VolumeMounts: []corev1.VolumeMount{
								{
									Name:      "gcloud-adc",
									MountPath: "/secrets/gcloud",
									ReadOnly:  true,
								},
								{
									Name:      "config",
									MountPath: "/config/config.json",
									SubPath:   "config.json",
									ReadOnly:  true,
								},
							},
						},
					},
					Volumes: []corev1.Volume{
						{
							Name: "gcloud-adc",
							VolumeSource: corev1.VolumeSource{
								Secret: &corev1.SecretVolumeSource{
									SecretName: params.GCloudSecret,
								},
							},
						},
						{
							Name: "config",
							VolumeSource: corev1.VolumeSource{
								ConfigMap: &corev1.ConfigMapVolumeSource{
									LocalObjectReference: corev1.LocalObjectReference{
										Name: params.ConfigsConfigMap,
									},
								},
							},
						},
					},
				},
			},
		},
	}

	_, err := c.clientset.BatchV1().Jobs(c.namespace).Create(ctx, job, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("creating job %s: %w", jobName, err)
	}
	return nil
}

func (c *K8sBackend) GetWorkflowStatus(ctx context.Context, jobID string) (*JobStatus, error) {
	jobName := "shift-workflow-" + jobID
	job, err := c.clientset.BatchV1().Jobs(c.namespace).Get(ctx, jobName, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("getting job %s: %w", jobName, err)
	}
	return jobStatusFromConditions(job), nil
}

func (c *K8sBackend) GetWorkflowInfo(ctx context.Context, jobID string) (*JobInfo, error) {
	jobName := "shift-workflow-" + jobID
	job, err := c.clientset.BatchV1().Jobs(c.namespace).Get(ctx, jobName, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("getting job %s: %w", jobName, err)
	}
	return jobInfoFromK8s(jobID, job), nil
}

func (c *K8sBackend) ListWorkflows(ctx context.Context) ([]JobInfo, error) {
	jobs, err := c.clientset.BatchV1().Jobs(c.namespace).List(ctx, metav1.ListOptions{
		LabelSelector: "app=shift-worker",
	})
	if err != nil {
		return nil, fmt.Errorf("listing jobs: %w", err)
	}

	var result []JobInfo
	for _, job := range jobs.Items {
		jobID := job.Labels["job-id"]
		if jobID == "" {
			continue
		}
		result = append(result, *jobInfoFromK8s(jobID, &job))
	}
	return result, nil
}

// StreamLogs waits for the worker pod, streams its logs as SSE events,
// and sends a final complete event.
func (c *K8sBackend) StreamLogs(ctx context.Context, id string, w http.ResponseWriter, flusher http.Flusher) error {
	// Phase 1: wait for pod (up to 5 minutes).
	var podName string
	deadline := time.Now().Add(5 * time.Minute)
	for {
		if time.Now().After(deadline) {
			fmt.Fprintf(w, "event: complete\ndata: %s\n\n",
				`{"status":"failed","message":"timed out waiting for pod"}`)
			flusher.Flush()
			return nil
		}

		select {
		case <-ctx.Done():
			return nil
		default:
		}

		name, err := c.getJobPod(ctx, id)
		if err == nil {
			podName = name
			break
		}

		fmt.Fprintf(w, "event: status\ndata: %s\n\n", `{"status":"waiting_for_pod"}`)
		flusher.Flush()

		select {
		case <-ctx.Done():
			return nil
		case <-time.After(2 * time.Second):
		}
	}

	// Phase 2: wait for pod to be running or terminated.
	for {
		select {
		case <-ctx.Done():
			return nil
		default:
		}

		pod, err := c.clientset.CoreV1().Pods(c.namespace).Get(ctx, podName, metav1.GetOptions{})
		if err != nil {
			fmt.Fprintf(w, "event: status\ndata: %s\n\n", `{"status":"waiting_for_pod"}`)
			flusher.Flush()
			time.Sleep(2 * time.Second)
			continue
		}

		phase := pod.Status.Phase
		if phase == corev1.PodRunning || phase == corev1.PodSucceeded || phase == corev1.PodFailed {
			break
		}

		fmt.Fprintf(w, "event: status\ndata: %s\n\n",
			fmt.Sprintf(`{"status":"pod_%s"}`, string(phase)))
		flusher.Flush()

		select {
		case <-ctx.Done():
			return nil
		case <-time.After(2 * time.Second):
		}
	}

	// Phase 3: stream pod logs.
	logStream, err := c.streamPodLogs(ctx, podName, true)
	if err != nil {
		log.Printf("ERROR: streaming logs for pod %s: %v", podName, err)
		fmt.Fprintf(w, "event: complete\ndata: %s\n\n",
			`{"status":"failed","message":"failed to stream logs"}`)
		flusher.Flush()
		return nil
	}
	defer logStream.Close()

	scanner := bufio.NewScanner(logStream)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return nil
		default:
		}
		line := scanner.Text()
		fmt.Fprintf(w, "event: log\ndata: %s\n\n", escapeSSE(line))
		flusher.Flush()
	}

	// Phase 4: send final status.
	status, err := c.GetWorkflowStatus(ctx, id)
	if err != nil {
		fmt.Fprintf(w, "event: complete\ndata: %s\n\n",
			`{"status":"unknown","message":"could not determine final status"}`)
	} else {
		data, _ := json.Marshal(status)
		fmt.Fprintf(w, "event: complete\ndata: %s\n\n", data)
	}
	flusher.Flush()
	return nil
}

// --- internal helpers ---

func (c *K8sBackend) getJobPod(ctx context.Context, jobID string) (string, error) {
	jobName := "shift-workflow-" + jobID
	pods, err := c.clientset.CoreV1().Pods(c.namespace).List(ctx, metav1.ListOptions{
		LabelSelector: "job-name=" + jobName,
	})
	if err != nil {
		return "", fmt.Errorf("listing pods for job %s: %w", jobName, err)
	}
	if len(pods.Items) == 0 {
		return "", fmt.Errorf("no pods found for job %s", jobName)
	}
	return pods.Items[0].Name, nil
}

func (c *K8sBackend) streamPodLogs(ctx context.Context, podName string, follow bool) (io.ReadCloser, error) {
	req := c.clientset.CoreV1().Pods(c.namespace).GetLogs(podName, &corev1.PodLogOptions{
		Follow: follow,
	})
	return req.Stream(ctx)
}

func jobStatusFromConditions(job *batchv1.Job) *JobStatus {
	for _, cond := range job.Status.Conditions {
		if cond.Type == batchv1.JobComplete && cond.Status == corev1.ConditionTrue {
			return &JobStatus{Status: "succeeded"}
		}
		if cond.Type == batchv1.JobFailed && cond.Status == corev1.ConditionTrue {
			return &JobStatus{Status: "failed", Message: cond.Message}
		}
	}
	if job.Status.Active > 0 {
		return &JobStatus{Status: "running"}
	}
	return &JobStatus{Status: "pending"}
}

func jobInfoFromK8s(jobID string, job *batchv1.Job) *JobInfo {
	info := &JobInfo{
		ID:        jobID,
		CreatedAt: job.CreationTimestamp.Format("2006-01-02T15:04:05Z"),
	}

	st := jobStatusFromConditions(job)
	info.Status = st.Status
	info.Message = st.Message

	if job.Annotations != nil {
		info.RepoURL = job.Annotations["app-platform-shift.openshift.github.io/repo-url"]
		info.EPUrl = job.Annotations["app-platform-shift.openshift.github.io/ep-url"]
		info.BaseBranch = job.Annotations["app-platform-shift.openshift.github.io/base-branch"]
		info.JiraTicket = job.Annotations["app-platform-shift.openshift.github.io/jira-ticket"]
	}

	return info
}
