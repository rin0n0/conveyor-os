package packages

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"conveyor-panel/internal/jobs"
)

const flathubURL = "https://dl.flathub.org/repo/flathub.flatpakrepo"

var validAppID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)

type CatalogItem struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Category    string `json:"category"`
	Description string `json:"description"`
	Installed   bool   `json:"installed"`
	Version     string `json:"version,omitempty"`
	HasUpdate   bool   `json:"has_update"`
	NewVersion  string `json:"new_version,omitempty"`
}

type InstalledApp struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Version      string `json:"version"`
	Origin       string `json:"origin"`
	Installation string `json:"installation"`
	HasUpdate    bool   `json:"has_update"`
	NewVersion   string `json:"new_version,omitempty"`
}

type SearchResult struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Version     string `json:"version"`
	Remotes     string `json:"remotes"`
	Installed   bool   `json:"installed"`
}

type Overview struct {
	FlathubReady bool           `json:"flathub_ready"`
	Catalog      []CatalogItem  `json:"catalog"`
	Installed    []InstalledApp `json:"installed"`
	UpdateCount  int            `json:"update_count"`
}

func baseCatalog() []CatalogItem {
	return []CatalogItem{
		{ID: "com.vscodium.codium", Name: "VSCodium", Category: "Разработка", Description: "Свободная сборка VS Code без телеметрии Microsoft"},
		{ID: "io.dbeaver.DBeaverCommunity", Name: "DBeaver", Category: "Разработка", Description: "Универсальный SQL-клиент и менеджер баз данных"},
		{ID: "com.usebruno.Bruno", Name: "Bruno API Client", Category: "Разработка", Description: "Офлайн-клиент для тестирования REST и GraphQL API"},
		{ID: "org.telegram.desktop", Name: "Telegram", Category: "Общение", Description: "Десктопный клиент Telegram"},
		{ID: "com.discordapp.Discord", Name: "Discord", Category: "Общение", Description: "Голосовой и текстовый мессенджер"},
		{ID: "md.obsidian.Obsidian", Name: "Obsidian", Category: "Заметки", Description: "База знаний в Markdown с графом связей"},
		{ID: "com.google.Chrome", Name: "Google Chrome", Category: "Браузеры", Description: "Браузер Chrome (в дополнение к встроенному Firefox)"},
		{ID: "org.libreoffice.LibreOffice", Name: "LibreOffice", Category: "Офис", Description: "Офисный пакет: документы, таблицы, презентации"},
		{ID: "org.gimp.GIMP", Name: "GIMP", Category: "Графика", Description: "Растровый графический редактор"},
		{ID: "org.blender.Blender", Name: "Blender", Category: "Графика", Description: "3D-моделирование, рендеринг и анимация"},
		{ID: "com.obsproject.Studio", Name: "OBS Studio", Category: "Медиа", Description: "Запись экрана и стриминг"},
		{ID: "org.videolan.VLC", Name: "VLC", Category: "Медиа", Description: "Универсальный видео- и аудиоплеер"},
	}
}

func isFlathubReady() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "flatpak", "remotes", "--columns=name").Output()
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(line) == "flathub" {
			return true
		}
	}
	return false
}

func listUpdates() map[string]string {
	updates := make(map[string]string)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, "flatpak", "remote-ls", "--updates", "--app", "--columns=application,version").Output()
	if err != nil {
		return updates
	}
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		cols := strings.Split(scanner.Text(), "\t")
		if len(cols) >= 1 {
			id := strings.TrimSpace(cols[0])
			ver := ""
			if len(cols) >= 2 {
				ver = strings.TrimSpace(cols[1])
			}
			if id != "" {
				updates[id] = ver
			}
		}
	}
	return updates
}

func ListInstalled() Overview {
	ov := Overview{
		FlathubReady: isFlathubReady(),
		Catalog:      baseCatalog(),
		Installed:    []InstalledApp{},
	}

	updates := listUpdates()
	installedMap := make(map[string]InstalledApp)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "flatpak", "list", "--app", "--columns=application,name,version,origin,installation").Output()
	if err == nil {
		scanner := bufio.NewScanner(bytes.NewReader(out))
		for scanner.Scan() {
			cols := strings.Split(scanner.Text(), "\t")
			if len(cols) < 2 {
				continue
			}
			app := InstalledApp{
				ID:   strings.TrimSpace(cols[0]),
				Name: strings.TrimSpace(cols[1]),
			}
			if len(cols) > 2 {
				app.Version = strings.TrimSpace(cols[2])
			}
			if len(cols) > 3 {
				app.Origin = strings.TrimSpace(cols[3])
			}
			if len(cols) > 4 {
				app.Installation = strings.TrimSpace(cols[4])
			}
			if newVer, ok := updates[app.ID]; ok {
				app.HasUpdate = true
				app.NewVersion = newVer
				ov.UpdateCount++
			}
			ov.Installed = append(ov.Installed, app)
			installedMap[app.ID] = app
		}
	}

	for i := range ov.Catalog {
		if inst, ok := installedMap[ov.Catalog[i].ID]; ok {
			ov.Catalog[i].Installed = true
			ov.Catalog[i].Version = inst.Version
			ov.Catalog[i].HasUpdate = inst.HasUpdate
			ov.Catalog[i].NewVersion = inst.NewVersion
		}
	}

	return ov
}

func SearchFlathub(query string) ([]SearchResult, error) {
	q := strings.TrimSpace(strings.TrimLeft(query, "-"))
	if len(q) < 2 {
		return []SearchResult{}, nil
	}

	ov := ListInstalled()
	instSet := make(map[string]bool, len(ov.Installed))
	for _, a := range ov.Installed {
		instSet[a.ID] = true
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, "flatpak", "search", "--columns=name,description,application,version,remotes", q).Output()
	if err != nil {
		// flatpak search returns exit code 1 or empty output when nothing matches
		if len(out) == 0 {
			return []SearchResult{}, nil
		}
	}

	results := make([]SearchResult, 0, 30)
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		cols := strings.Split(scanner.Text(), "\t")
		if len(cols) < 3 {
			continue
		}
		id := strings.TrimSpace(cols[2])
		if id == "" || id == "Application ID" {
			continue
		}
		res := SearchResult{
			Name:        strings.TrimSpace(cols[0]),
			Description: strings.TrimSpace(cols[1]),
			ID:          id,
			Installed:   instSet[id],
		}
		if len(cols) > 3 {
			res.Version = strings.TrimSpace(cols[3])
		}
		if len(cols) > 4 {
			res.Remotes = strings.TrimSpace(cols[4])
		}
		results = append(results, res)
		if len(results) >= 30 {
			break
		}
	}
	return results, nil
}

func ValidateAppID(appID string) error {
	if !validAppID.MatchString(appID) || strings.Contains(appID, "..") {
		return fmt.Errorf("некорректный Flatpak ID: %q", appID)
	}
	return nil
}

func ensureFlathub(emit func(string)) error {
	if isFlathubReady() {
		return nil
	}
	emit("Подключаю репозиторий Flathub (--user)...")
	cmd := exec.Command("flatpak", "remote-add", "--user", "--if-not-exists", "flathub", flathubURL)
	out, err := cmd.CombinedOutput()
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line != "" {
			emit(line)
		}
	}
	return err
}

func runFlatpakStream(emit func(string), args ...string) error {
	cmd := exec.Command("flatpak", args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return err
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 256*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line != "" {
			emit(line)
		}
	}
	return cmd.Wait()
}

func Install(jm *jobs.Manager, appID string) (*jobs.Job, error) {
	if err := ValidateAppID(appID); err != nil {
		return nil, err
	}
	j := jm.StartFunc("Установка "+appID, func(emit func(string)) error {
		if err := ensureFlathub(emit); err != nil {
			return fmt.Errorf("не удалось подключить Flathub: %w", err)
		}
		emit("Устанавливаю " + appID + "...")
		return runFlatpakStream(emit, "install", "-y", "--noninteractive", "--user", "flathub", appID)
	})
	return j, nil
}

func Update(jm *jobs.Manager, appID string) (*jobs.Job, error) {
	if appID != "" {
		if err := ValidateAppID(appID); err != nil {
			return nil, err
		}
		return jm.Start("Обновление "+appID, "flatpak", "update", "-y", "--noninteractive", appID)
	}
	return jm.Start("Обновление всех Flatpak-пакетов", "flatpak", "update", "-y", "--noninteractive")
}

func Uninstall(jm *jobs.Manager, appID string) (*jobs.Job, error) {
	if err := ValidateAppID(appID); err != nil {
		return nil, err
	}
	return jm.Start("Удаление "+appID, "flatpak", "uninstall", "-y", "--noninteractive", appID)
}
