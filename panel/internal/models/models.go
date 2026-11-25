package models

import (
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"conveyor-panel/internal/jobs"
)

const (
	ModelsDir  = "/var/lib/models"
	SharedDir  = "/mnt/shared/models"
	SharedRoot = "/mnt/shared"
	SharedComfy = "/mnt/shared/models/comfyui"
)

var validFilename = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

type RoleInfo struct {
	Role        string `json:"role"`
	Label       string `json:"label"`
	Description string `json:"description"`
	Assigned    bool   `json:"assigned"`
	Broken      bool   `json:"broken"`
	TargetPath  string `json:"target_path,omitempty"`
	FileName    string `json:"file_name,omitempty"`
	SizeBytes   int64  `json:"size_bytes,omitempty"`
}

type WeightFile struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	SizeBytes int64  `json:"size_bytes"`
	Ext       string `json:"ext"`
	Location  string `json:"location"`
}

type ComfyOverview struct {
	Checkpoints []WeightFile `json:"checkpoints"`
	Loras       []WeightFile `json:"loras"`
}

type Overview struct {
	Roles           []RoleInfo   `json:"roles"`
	DiscoveredFiles []WeightFile `json:"discovered_files"`
	Comfy           ComfyOverview `json:"comfy"`
}

func homeDirs() (downloads string, comfy string) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = "/var/home/conveyor"
	}
	return filepath.Join(home, "Downloads"), filepath.Join(home, "comfyui", "models")
}

func roleSpecs() []struct {
	role  string
	label string
	desc  string
} {
	return []struct {
		role  string
		label string
		desc  string
	}{
		{"coder", "Код (coder)", "Основная модель для Aider, OpenCode и редакторов (gpt-4o / claude-3-5-sonnet)"},
		{"fast", "Быстрая (fast)", "Короткие ответы, триаж задач и быстрый чат (gpt-4o-mini / chat)"},
		{"think", "Рассуждения (think)", "Сложные алгоритмы, математика и DeepSeek-R1 / o1"},
		{"embed", "Эмбеддинги (embed)", "Векторный поиск и RAG на CPU (0 МБ VRAM)"},
	}
}

func GetOverview() Overview {
	downloadsDir, comfyDir := homeDirs()
	ov := Overview{
		Roles:           make([]RoleInfo, 0, 4),
		DiscoveredFiles: []WeightFile{},
		Comfy: ComfyOverview{
			Checkpoints: []WeightFile{},
			Loras:       []WeightFile{},
		},
	}

	for _, spec := range roleSpecs() {
		info := RoleInfo{
			Role:        spec.role,
			Label:       spec.label,
			Description: spec.desc,
		}
		linkPath := filepath.Join(ModelsDir, fmt.Sprintf("active-%s.gguf", spec.role))
		if rawTarget, err := os.Readlink(linkPath); err == nil {
			info.Assigned = true
			info.TargetPath = rawTarget
			info.FileName = filepath.Base(rawTarget)
			if resolved, evalErr := filepath.EvalSymlinks(linkPath); evalErr == nil {
				info.TargetPath = resolved
				info.FileName = filepath.Base(resolved)
				if st, stErr := os.Stat(resolved); stErr == nil {
					info.SizeBytes = st.Size()
				} else {
					info.Broken = true
				}
			} else {
				info.Broken = true
			}
		}
		ov.Roles = append(ov.Roles, info)
	}

	ov.Comfy.Checkpoints = scanComfySubdir("checkpoints", comfyDir)
	ov.Comfy.Loras = scanComfySubdir("loras", comfyDir)

	// Discover weight files across standard locations
	seen := make(map[string]bool)
	scanRoots := []struct {
		dir      string
		location string
	}{
		{SharedDir, "Диск E: (SHARED/models)"},
		{SharedRoot, "Диск E: (SHARED)"},
		{downloadsDir, "Загрузки (~/Downloads)"},
		{ModelsDir, "Локальные (@models)"},
	}

	for _, root := range scanRoots {
		files := walkWeights(root.dir, root.location, 3)
		for _, wf := range files {
			canon := wf.Path
			if resolved, err := filepath.EvalSymlinks(wf.Path); err == nil {
				canon = resolved
			}
			if seen[canon] {
				continue
			}
			seen[canon] = true
			ov.DiscoveredFiles = append(ov.DiscoveredFiles, wf)
		}
	}

	sort.Slice(ov.DiscoveredFiles, func(i, j int) bool {
		return ov.DiscoveredFiles[i].Name < ov.DiscoveredFiles[j].Name
	})

	return ov
}

func scanComfySubdir(subdir, homeComfy string) []WeightFile {
	out := []WeightFile{}
	seen := make(map[string]bool)
	dirs := []struct {
		dir string
		loc string
	}{
		{filepath.Join(SharedComfy, subdir), "SHARED/comfyui/" + subdir},
		{filepath.Join(homeComfy, subdir), "~/comfyui/models/" + subdir},
	}
	for _, d := range dirs {
		entries, err := os.ReadDir(d.dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			ext := strings.ToLower(filepath.Ext(e.Name()))
			if ext != ".safetensors" && ext != ".ckpt" && ext != ".pt" {
				continue
			}
			full := filepath.Join(d.dir, e.Name())
			canon := full
			if r, err := filepath.EvalSymlinks(full); err == nil {
				canon = r
			}
			if seen[canon] {
				continue
			}
			seen[canon] = true
			var sz int64
			if st, err := os.Stat(full); err == nil {
				sz = st.Size()
			}
			out = append(out, WeightFile{
				Name:      e.Name(),
				Path:      full,
				SizeBytes: sz,
				Ext:       ext,
				Location:  d.loc,
			})
		}
	}
	return out
}

func walkWeights(rootDir, location string, maxDepth int) []WeightFile {
	out := []WeightFile{}
	info, err := os.Stat(rootDir)
	if err != nil || !info.IsDir() {
		return out
	}

	cleanRoot := filepath.Clean(rootDir)
	_ = filepath.WalkDir(cleanRoot, func(p string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		rel, err := filepath.Rel(cleanRoot, p)
		if err != nil {
			return nil
		}
		depth := 0
		if rel != "." {
			depth = strings.Count(rel, string(os.PathSeparator)) + 1
		}
		if d.IsDir() {
			if depth > maxDepth || strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}

		// Skip active-*.gguf symlinks
		if strings.HasPrefix(d.Name(), "active-") && strings.HasSuffix(d.Name(), ".gguf") {
			return nil
		}

		ext := strings.ToLower(filepath.Ext(d.Name()))
		if ext != ".gguf" && ext != ".safetensors" && ext != ".ckpt" {
			return nil
		}

		st, err := os.Stat(p)
		if err != nil || !st.Mode().IsRegular() {
			return nil
		}

		out = append(out, WeightFile{
			Name:      d.Name(),
			Path:      p,
			SizeBytes: st.Size(),
			Ext:       ext,
			Location:  location,
		})
		return nil
	})
	return out
}

func UnloadAll() {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Post("http://127.0.0.1:8080/api/models/unload", "application/json", nil)
	if err == nil {
		_ = resp.Body.Close()
	}
}

func Unassign(role string) error {
	switch role {
	case "coder", "fast", "think", "embed":
	default:
		return fmt.Errorf("неизвестная роль: %s", role)
	}
	linkPath := filepath.Join(ModelsDir, fmt.Sprintf("active-%s.gguf", role))
	if err := os.Remove(linkPath); err != nil && !os.IsNotExist(err) {
		return err
	}
	UnloadAll()
	return nil
}

func Assign(jm *jobs.Manager, srcPath, role, mode string) (*jobs.Job, error) {
	if mode == "" {
		mode = "link"
	}
	if mode != "link" && mode != "copy" {
		return nil, fmt.Errorf("режим должен быть link или copy")
	}

	absSrc, err := filepath.Abs(srcPath)
	if err != nil {
		return nil, err
	}
	if resolved, err := filepath.EvalSymlinks(absSrc); err == nil {
		absSrc = resolved
	}
	st, err := os.Stat(absSrc)
	if err != nil || !st.Mode().IsRegular() {
		return nil, fmt.Errorf("файл не найден: %s", srcPath)
	}

	ext := strings.ToLower(filepath.Ext(absSrc))

	switch role {
	case "coder", "fast", "think", "embed":
		if ext != ".gguf" {
			return nil, fmt.Errorf("для роли %s требуется файл .gguf", role)
		}
		if mode == "link" {
			if err := linkLLMRole(absSrc, role); err != nil {
				return nil, err
			}
			return nil, nil
		}
		j := jm.StartFunc(fmt.Sprintf("Копирование %s -> [%s]", filepath.Base(absSrc), role), func(emit func(string)) error {
			if err := os.MkdirAll(ModelsDir, 0o775); err != nil {
				return err
			}
			dest := filepath.Join(ModelsDir, filepath.Base(absSrc))
			if absSrc != dest {
				emit("Копирую файл в " + dest + "...")
				if err := copyFile(absSrc, dest); err != nil {
					return err
				}
			}
			emit("Назначаю роль [" + role + "]...")
			return linkLLMRole(dest, role)
		})
		return j, nil

	case "comfy-checkpoint", "comfy-lora":
		if ext != ".safetensors" && ext != ".ckpt" && ext != ".pt" {
			return nil, fmt.Errorf("для %s требуется .safetensors, .ckpt или .pt", role)
		}
		subdir := "checkpoints"
		if role == "comfy-lora" {
			subdir = "loras"
		}
		sharedTargetDir := filepath.Join(SharedComfy, subdir)
		_, homeComfy := homeDirs()
		homeTargetDir := filepath.Join(homeComfy, subdir)

		if mode == "copy" && !strings.HasPrefix(absSrc, sharedTargetDir+string(os.PathSeparator)) {
			j := jm.StartFunc(fmt.Sprintf("Копирование %s -> [%s]", filepath.Base(absSrc), role), func(emit func(string)) error {
				if err := os.MkdirAll(sharedTargetDir, 0o755); err != nil {
					return err
				}
				dest := filepath.Join(sharedTargetDir, filepath.Base(absSrc))
				emit("Копирую в " + dest + "...")
				if err := copyFile(absSrc, dest); err != nil {
					return err
				}
				return linkComfyHome(dest, homeTargetDir)
			})
			return j, nil
		}

		// Never create symlinks inside /mnt/shared (exFAT); symlink inside Btrfs ~/comfyui if present
		if err := linkComfyHome(absSrc, homeTargetDir); err != nil {
			return nil, err
		}
		return nil, nil

	default:
		return nil, fmt.Errorf("неизвестная роль: %s", role)
	}
}

func linkLLMRole(targetPath, role string) error {
	if err := os.MkdirAll(ModelsDir, 0o775); err != nil {
		return err
	}
	linkPath := filepath.Join(ModelsDir, fmt.Sprintf("active-%s.gguf", role))
	tmpLink := linkPath + ".tmp"
	_ = os.Remove(tmpLink)
	if err := os.Symlink(targetPath, tmpLink); err != nil {
		return err
	}
	if err := os.Rename(tmpLink, linkPath); err != nil {
		_ = os.Remove(tmpLink)
		return err
	}
	UnloadAll()
	return nil
}

func linkComfyHome(targetPath, homeTargetDir string) error {
	comfyBase := filepath.Dir(filepath.Dir(homeTargetDir))
	if _, err := os.Stat(comfyBase); err != nil {
		// ~/comfyui is not installed yet; conveyor-comfyui.sh links shared models on first run
		return nil
	}
	if err := os.MkdirAll(homeTargetDir, 0o755); err != nil {
		return err
	}
	linkPath := filepath.Join(homeTargetDir, filepath.Base(targetPath))
	tmpLink := linkPath + ".tmp"
	_ = os.Remove(tmpLink)
	if err := os.Symlink(targetPath, tmpLink); err != nil {
		return err
	}
	return os.Rename(tmpLink, linkPath)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	tmp := dst + ".part"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

func DownloadModel(jm *jobs.Manager, rawURL, dest, role string) (*jobs.Job, error) {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return nil, fmt.Errorf("допустимы только URL с http:// или https://")
	}

	baseName := path.Base(parsed.Path)
	baseName = validFilename.ReplaceAllString(baseName, "_")
	if baseName == "" || baseName == "." || baseName == "/" || baseName == "_" {
		baseName = fmt.Sprintf("model-%d.gguf", time.Now().Unix())
	}

	targetDir := SharedDir
	if dest == "local" {
		targetDir = ModelsDir
	} else if role == "comfy-checkpoint" {
		targetDir = filepath.Join(SharedComfy, "checkpoints")
	} else if role == "comfy-lora" {
		targetDir = filepath.Join(SharedComfy, "loras")
	}

	targetPath := filepath.Join(targetDir, baseName)

	j := jm.StartFunc("Скачивание "+baseName, func(emit func(string)) error {
		if err := os.MkdirAll(targetDir, 0o755); err != nil {
			return err
		}
		emit("URL: " + parsed.String())
		emit("Сохраняю в: " + targetPath)

		subJob, err := jm.Start("curl-hidden-"+baseName, "curl", "-C", "-", "-fL", "--progress-bar", "-o", targetPath, parsed.String())
		if err != nil {
			return err
		}
		// Forward curl output into this parent job stream
		snap, st, code, ch, unsub, found := jm.Subscribe(subJob.ID)
		if !found {
			return fmt.Errorf("не удалось отследить процесс curl")
		}
		for _, line := range snap {
			emit(line)
		}
		if st == jobs.StatusRunning && ch != nil {
			for line := range ch {
				emit(line)
			}
			unsub()
			_, st, code, _, _, _ = jm.Subscribe(subJob.ID)
		}
		if st != jobs.StatusDone || code != 0 {
			return fmt.Errorf("curl завершился с кодом %d", code)
		}

		if role != "" {
			emit("Подключаю модель к роли [" + role + "]...")
			if _, assignErr := Assign(jm, targetPath, role, "link"); assignErr != nil {
				return assignErr
			}
			emit("Роль [" + role + "] успешно назначена!")
		}
		return nil
	})
	return j, nil
}
