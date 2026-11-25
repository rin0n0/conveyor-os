package sysinfo

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"time"
)

type Status struct {
	Hostname        string   `json:"hostname"`
	Username        string   `json:"username"`
	GPUBackend      string   `json:"gpu_backend"`
	GPUName         string   `json:"gpu_name,omitempty"`
	VRAMGiB         int      `json:"vram_gib"`
	VRAMUsedMiB     int      `json:"vram_used_mib"`
	VRAMTotalMiB    int      `json:"vram_total_mib"`
	RAMGiB          int      `json:"ram_gib"`
	LlamaDevices    string   `json:"llama_devices"`
	LlamaProfile    string   `json:"llama_profile"`
	LlamaSwapOnline bool     `json:"llama_swap_online"`
	LlamaSwapModels []string `json:"llama_swap_models"`
}

func GetStatus() Status {
	s := Status{
		GPUBackend:      "cpu",
		LlamaSwapModels: []string{},
	}

	if h, err := os.Hostname(); err == nil {
		s.Hostname = h
	}
	if u, err := user.Current(); err == nil {
		s.Username = u.Username
	}

	parseGPUEnv(&s)
	queryNvidiaLive(&s)
	queryLlamaSwap(&s)

	return s
}

func parseGPUEnv(s *Status) {
	f, err := os.Open("/run/gpu-profile.env")
	if err != nil {
		return
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		v = strings.Trim(v, `"'`)
		switch k {
		case "GPU_BACKEND":
			s.GPUBackend = v
		case "VRAM_GIB":
			if n, convErr := strconv.Atoi(v); convErr == nil {
				s.VRAMGiB = n
			}
		case "RAM_GIB":
			if n, convErr := strconv.Atoi(v); convErr == nil {
				s.RAMGiB = n
			}
		case "LLAMA_DEVICES":
			s.LlamaDevices = v
		case "LLAMA_PROFILE":
			s.LlamaProfile = v
		}
	}
}

func queryNvidiaLive(s *Status) {
	if _, err := os.Stat("/sys/module/nvidia"); err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	out, err := exec.CommandContext(
		ctx,
		"nvidia-smi",
		"--query-gpu=name,memory.used,memory.total",
		"--format=csv,noheader,nounits",
	).Output()
	if err != nil {
		return
	}

	firstLine := strings.Split(strings.TrimSpace(string(out)), "\n")[0]
	parts := strings.Split(firstLine, ",")
	if len(parts) < 3 {
		return
	}
	s.GPUName = strings.TrimSpace(parts[0])
	if used, err := strconv.Atoi(strings.TrimSpace(parts[1])); err == nil {
		s.VRAMUsedMiB = used
	}
	if total, err := strconv.Atoi(strings.TrimSpace(parts[2])); err == nil {
		s.VRAMTotalMiB = total
	}
}

func queryLlamaSwap(s *Status) {
	client := &http.Client{Timeout: 1500 * time.Millisecond}
	resp, err := client.Get("http://127.0.0.1:8080/v1/models")
	if err != nil {
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return
	}
	s.LlamaSwapOnline = true

	var payload struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err == nil {
		for _, item := range payload.Data {
			if item.ID != "" {
				s.LlamaSwapModels = append(s.LlamaSwapModels, item.ID)
			}
		}
	}
}
