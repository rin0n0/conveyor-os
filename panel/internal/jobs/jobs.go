package jobs

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os/exec"
	"sync"
	"sync/atomic"
	"time"
)

type Status string

const (
	StatusRunning Status = "running"
	StatusDone    Status = "done"
	StatusFailed  Status = "failed"
)

const maxJobs = 50

type Job struct {
	ID         string     `json:"id"`
	Title      string     `json:"title"`
	Status     Status     `json:"status"`
	ExitCode   int        `json:"exit_code"`
	StartedAt  time.Time  `json:"started_at"`
	FinishedAt *time.Time `json:"finished_at,omitempty"`
	Logs       []string   `json:"logs"`

	mu   sync.Mutex
	subs map[chan string]struct{}
}

type Manager struct {
	mu      sync.RWMutex
	jobs    map[string]*Job
	order   []string
	counter atomic.Uint64
}

func NewManager() *Manager {
	return &Manager{
		jobs: make(map[string]*Job),
	}
}

func (m *Manager) createJob(title string) *Job {
	n := m.counter.Add(1)
	id := fmt.Sprintf("job-%d-%d", time.Now().Unix(), n)
	j := &Job{
		ID:        id,
		Title:     title,
		Status:    StatusRunning,
		StartedAt: time.Now(),
		Logs:      make([]string, 0, 32),
		subs:      make(map[chan string]struct{}),
	}

	m.mu.Lock()
	m.jobs[id] = j
	m.order = append(m.order, id)
	if len(m.order) > maxJobs {
		evict := m.order[0]
		m.order = m.order[1:]
		if old, ok := m.jobs[evict]; ok {
			old.mu.Lock()
			done := old.Status != StatusRunning
			old.mu.Unlock()
			if done {
				delete(m.jobs, evict)
			}
		}
	}
	m.mu.Unlock()

	return j
}

func (j *Job) emit(line string) {
	j.mu.Lock()
	if len(j.Logs) > 2000 {
		// Keep the last 1500 lines to bound memory on huge installs
		j.Logs = append([]string(nil), j.Logs[len(j.Logs)-1500:]...)
	}
	j.Logs = append(j.Logs, line)
	for ch := range j.subs {
		select {
		case ch <- line:
		default:
			// Drop slow subscriber lines rather than blocking command output
		}
	}
	j.mu.Unlock()
}

func (j *Job) finish(exitCode int) {
	now := time.Now()
	j.mu.Lock()
	j.ExitCode = exitCode
	j.FinishedAt = &now
	if exitCode == 0 {
		j.Status = StatusDone
	} else {
		j.Status = StatusFailed
	}
	for ch := range j.subs {
		close(ch)
		delete(j.subs, ch)
	}
	j.mu.Unlock()
}

// Start runs a single external command in the background and streams its combined output.
func (m *Manager) Start(title string, cmdName string, args ...string) (*Job, error) {
	cmd := exec.Command(cmdName, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = cmd.Stdout

	if err := cmd.Start(); err != nil {
		return nil, err
	}

	j := m.createJob(title)
	go func() {
		scanLines(stdout, j.emit)
		waitErr := cmd.Wait()
		code := 0
		if waitErr != nil {
			code = 1
			if ee, ok := waitErr.(*exec.ExitError); ok {
				code = ee.ExitCode()
			}
			j.emit(fmt.Sprintf("[error] %v", waitErr))
		}
		j.finish(code)
	}()

	return j, nil
}

// StartFunc runs a multi-step background function that emits log lines via emit.
func (m *Manager) StartFunc(title string, fn func(emit func(string)) error) *Job {
	j := m.createJob(title)
	go func() {
		err := fn(j.emit)
		if err != nil {
			j.emit(fmt.Sprintf("[error] %v", err))
			j.finish(1)
			return
		}
		j.finish(0)
	}()
	return j
}

// List returns recent jobs newest-first without full log slices for fast polling.
func (m *Manager) List() []Job {
	m.mu.RLock()
	defer m.mu.RUnlock()

	out := make([]Job, 0, len(m.order))
	for i := len(m.order) - 1; i >= 0; i-- {
		j, ok := m.jobs[m.order[i]]
		if !ok {
			continue
		}
		j.mu.Lock()
		tailStart := 0
		if len(j.Logs) > 20 {
			tailStart = len(j.Logs) - 20
		}
		logsCopy := append([]string(nil), j.Logs[tailStart:]...)
		out = append(out, Job{
			ID:         j.ID,
			Title:      j.Title,
			Status:     j.Status,
			ExitCode:   j.ExitCode,
			StartedAt:  j.StartedAt,
			FinishedAt: j.FinishedAt,
			Logs:       logsCopy,
		})
		j.mu.Unlock()
	}
	return out
}

// Subscribe returns a snapshot of existing logs, whether the job already finished,
// a live channel for subsequent lines, and an unsubscribe function.
func (m *Manager) Subscribe(id string) (snapshot []string, status Status, exitCode int, ch <-chan string, unsub func(), found bool) {
	m.mu.RLock()
	j, ok := m.jobs[id]
	m.mu.RUnlock()
	if !ok {
		return nil, "", 0, nil, func() {}, false
	}

	j.mu.Lock()
	defer j.mu.Unlock()

	snapshot = append([]string(nil), j.Logs...)
	status = j.Status
	exitCode = j.ExitCode
	if j.Status != StatusRunning {
		return snapshot, status, exitCode, nil, func() {}, true
	}

	subCh := make(chan string, 128)
	j.subs[subCh] = struct{}{}
	unsub = func() {
		j.mu.Lock()
		if _, exists := j.subs[subCh]; exists {
			delete(j.subs, subCh)
			close(subCh)
		}
		j.mu.Unlock()
	}
	return snapshot, status, exitCode, subCh, unsub, true
}

// scanLines splits on both \n and \r so progress bars (curl, flatpak) stream cleanly.
func scanLines(r io.Reader, emit func(string)) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 256*1024)
	scanner.Split(func(data []byte, atEOF bool) (advance int, token []byte, err error) {
		if atEOF && len(data) == 0 {
			return 0, nil, nil
		}
		for i, b := range data {
			if b == '\n' || b == '\r' {
				return i + 1, bytes.TrimRight(data[:i], "\r\n"), nil
			}
		}
		if atEOF {
			return len(data), bytes.TrimRight(data, "\r\n"), nil
		}
		return 0, nil, nil
	})
	for scanner.Scan() {
		line := string(bytes.TrimSpace(scanner.Bytes()))
		if line != "" {
			emit(line)
		}
	}
}
