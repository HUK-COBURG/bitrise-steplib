package main

import (
    "encoding/json"
    "fmt"
    "io/ioutil"
    "net/http"
    "net/url"
    "os"
    "regexp"
    "strconv"
    "strings"
    "time"

    "github.com/bitrise-io/go-steputils/stepconf"
    "github.com/bitrise-io/go-utils/log"
    "github.com/bitrise-io/go-utils/retry"
)

type config struct {
    PrivateToken    string  `env:"private_token,required"`
    RepositoryURL   string  `env:"repository_url,required"`
    GitRef          string  `env:"git_ref"`
    CommitHash      string  `env:"commit_hash,required"`
    APIURL          string  `env:"api_base_url,required"`
    MergeRequestID  string  `env:"merge_request_id"`
    Status          string  `env:"preset_status,opt[auto,pending,running,success,failed,canceled]"`
    TargetURL       string  `env:"target_url"`
    Context         string  `env:"context"`
    Description     string  `env:"description"`
    Coverage        float64 `env:"coverage,range[0.0..100.0]"`
}

// getRepo parses the repository from a url
func getRepo(u string) string {
    r := regexp.MustCompile(`(?::\/\/[^/]+?\/|[^:/]+?:)([^/]+?\/.+?)(?:\.git)?\/?$`)
    if matches := r.FindStringSubmatch(u); len(matches) == 2 {
        return matches[1]
    }
    return ""
}

func getState(preset string) string {
    if preset != "auto" {
        return preset
    }
    if os.Getenv("BITRISE_BUILD_STATUS") == "0" {
        return "success"
    }
    return "failed"
}

func getDescription(desc, state string) string {
    if desc == "" {
        return strings.Title(getState(state))
    }
    return desc
}

type mrPipeline struct {
    ID     int    `json:"id"`
    Source string `json:"source"`
}

func fetchMergeRequestPipelineID(cfg config, repo string) (string, error) {
    if strings.TrimSpace(cfg.MergeRequestID) == "" {
        return "", nil
    }

    urlStr := fmt.Sprintf("%s/projects/%s/merge_requests/%s/pipelines", cfg.APIURL, repo, url.PathEscape(strings.TrimSpace(cfg.MergeRequestID)))
    req, err := http.NewRequest("GET", urlStr, nil)
    if err != nil {
        return "", err
    }
    req.Header.Add("PRIVATE-TOKEN", cfg.PrivateToken)

    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        return "", fmt.Errorf("failed to query MR pipelines: %s", err)
    }
    defer func() {
        _ = resp.Body.Close()
    }()

    if 200 > resp.StatusCode || resp.StatusCode >= 300 {
        body, _ := ioutil.ReadAll(resp.Body)
        return "", fmt.Errorf("server error querying MR pipelines: %s url: %s code: %d body: %s", resp.Status, urlStr, resp.StatusCode, string(body))
    }

    body, err := ioutil.ReadAll(resp.Body)
    if err != nil {
        return "", err
    }

    var pipelines []mrPipeline
    if err := json.Unmarshal(body, &pipelines); err != nil {
        return "", fmt.Errorf("failed to parse MR pipelines response: %w", err)
    }

    for _, p := range pipelines {
        if p.Source == "merge_request_event" {
            return strconv.Itoa(p.ID), nil
        }
    }

    return "", nil
}

// sendStatus creates a commit status for the given commit.
// see also: https://docs.gitlab.com/ce/api/commits.html#post-the-build-status-to-a-commit
func sendStatus(cfg config) error {
    repo := url.PathEscape(getRepo(cfg.RepositoryURL))
    form := url.Values{
        "state":       {getState(cfg.Status)},
        "target_url":  {cfg.TargetURL},
        "description": {getDescription(cfg.Description, cfg.Status)},
        "context":     {cfg.Context},
        "coverage":    {fmt.Sprintf("%f", cfg.Coverage)},
    }

    if strings.TrimSpace(cfg.GitRef) != "" {
        form["ref"] = []string{strings.TrimSpace(cfg.GitRef)}
    }

    // Optionally attach pipeline_id from MR pipelines
    if strings.TrimSpace(cfg.MergeRequestID) != "" {
        pipelineID, err := fetchMergeRequestPipelineID(cfg, repo)
        if err == nil {
            // Non-fatal: proceed without pipeline_id if fetching fails
            log.Warnf("Failed to fetch merge request pipelines: %s", err)
        } else if pipelineID != "" {
            form["pipeline_id"] = []string{pipelineID}
        }
    }

    url := fmt.Sprintf("%s/projects/%s/statuses/%s", cfg.APIURL, repo, cfg.CommitHash)
    req, err := http.NewRequest("POST", url, strings.NewReader(form.Encode()))
    if err != nil {
        return err
    }
    req.Header.Add("PRIVATE-TOKEN", cfg.PrivateToken)
    req.Header.Add("Content-Type", "application/x-www-form-urlencoded")

    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        return fmt.Errorf("failed to send the request: %s", err)
    }

    body, err := ioutil.ReadAll(resp.Body)
    if err != nil {
        return err
    }

    if err := resp.Body.Close(); err != nil {
        return err
    }
    if 200 > resp.StatusCode || resp.StatusCode >= 300 {
        return fmt.Errorf("server error: %s url: %s code: %d body: %s", resp.Status, url, resp.StatusCode, string(body))
    }

    return err
}

func main() {
    if os.Getenv("commit_hash") == "" {
        log.Warnf("GitLab requires a commit hash for build status reporting")
        os.Exit(1)
    }

    var cfg config
    if err := stepconf.Parse(&cfg); err != nil {
        log.Errorf("Error: %s\n", err)
        os.Exit(1)
    }
    stepconf.Print(cfg)

    if err := retry.Times(3).Wait(5 * time.Second).Try(func(attempt uint) error {
        if attempt > 0 {
            log.Warnf("%d attempt failed", attempt)
        }

        return sendStatus(cfg)
    }); err != nil {
        log.Errorf("Failed to set status, error: %s", err)
        os.Exit(1)
    }
}
