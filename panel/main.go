package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"conveyor-panel/internal/jobs"
	"conveyor-panel/internal/models"
	"conveyor-panel/internal/packages"
	"conveyor-panel/internal/sysinfo"
)

const version = "1.0.0"

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func csrfGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Method != http.MethodOptions {
			if origin := r.Header.Get("Origin"); origin != "" {
				if !strings.HasPrefix(origin, "http://127.0.0.1:") &&
					!strings.HasPrefix(origin, "http://localhost:") &&
					origin != "http://127.0.0.1" &&
					origin != "http://localhost" {
					writeError(w, http.StatusForbidden, "Forbidden cross-origin request")
					return
				}
			}
			if sfs := r.Header.Get("Sec-Fetch-Site"); sfs != "" && sfs != "same-origin" && sfs != "none" {
				writeError(w, http.StatusForbidden, "Forbidden cross-site request")
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func main() {
	showVersion := flag.Bool("version", false, "Print version and exit")
	listenAddr := flag.String("listen", "127.0.0.1:7070", "Listen address")
	flag.Parse()

	if *showVersion {
		fmt.Printf("conveyor-panel %s\n", version)
		return
	}

	jm := jobs.NewManager()
	mux := http.NewServeMux()

	// System overview
	mux.HandleFunc("GET /api/system", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, sysinfo.GetStatus())
	})

	// Packages API
	mux.HandleFunc("GET /api/packages", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, packages.ListInstalled())
	})

	mux.HandleFunc("GET /api/packages/search", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		res, err := packages.SearchFlathub(q)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"results": res})
	})

	mux.HandleFunc("POST /api/packages/install", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID string `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "Неверный JSON")
			return
		}
		job, err := packages.Install(jm, req.ID)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]any{"job": job})
	})

	mux.HandleFunc("POST /api/packages/update", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID string `json:"id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		job, err := packages.Update(jm, req.ID)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]any{"job": job})
	})

	mux.HandleFunc("POST /api/packages/uninstall", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID string `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "Неверный JSON")
			return
		}
		job, err := packages.Uninstall(jm, req.ID)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]any{"job": job})
	})

	// Models API
	mux.HandleFunc("GET /api/models", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, models.GetOverview())
	})

	mux.HandleFunc("POST /api/models/assign", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Path string `json:"path"`
			Role string `json:"role"`
			Mode string `json:"mode"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "Неверный JSON")
			return
		}
		job, err := models.Assign(jm, req.Path, req.Role, req.Mode)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		if job != nil {
			writeJSON(w, http.StatusAccepted, map[string]any{"job": job})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "overview": models.GetOverview()})
	})

	mux.HandleFunc("DELETE /api/models/role/{role}", func(w http.ResponseWriter, r *http.Request) {
		role := r.PathValue("role")
		if err := models.Unassign(role); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "overview": models.GetOverview()})
	})

	mux.HandleFunc("POST /api/models/unload", func(w http.ResponseWriter, r *http.Request) {
		models.UnloadAll()
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})

	mux.HandleFunc("POST /api/models/download", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			URL  string `json:"url"`
			Dest string `json:"dest"`
			Role string `json:"role"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "Неверный JSON")
			return
		}
		job, err := models.DownloadModel(jm, req.URL, req.Dest, req.Role)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]any{"job": job})
	})

	// Jobs & SSE Log Streaming
	mux.HandleFunc("GET /api/jobs", func(w http.ResponseWriter, r *http.Request) {
		list := jm.List()
		filtered := make([]jobs.Job, 0, len(list))
		for _, j := range list {
			if strings.HasPrefix(j.Title, "curl-hidden-") {
				continue
			}
			filtered = append(filtered, j)
		}
		writeJSON(w, http.StatusOK, map[string]any{"jobs": filtered})
	})

	mux.HandleFunc("GET /api/jobs/{id}/stream", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		snapshot, status, exitCode, ch, unsub, found := jm.Subscribe(id)
		if !found {
			writeError(w, http.StatusNotFound, "Задача не найдена")
			return
		}
		defer unsub()

		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")

		flusher, ok := w.(http.Flusher)
		if !ok {
			writeError(w, http.StatusInternalServerError, "Streaming unsupported")
			return
		}

		sendEvent := func(event string, data any) {
			b, _ := json.Marshal(data)
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, b)
			flusher.Flush()
		}

		for _, line := range snapshot {
			sendEvent("log", map[string]string{"line": line})
		}

		if status != jobs.StatusRunning || ch == nil {
			sendEvent("done", map[string]any{"status": status, "exit_code": exitCode})
			return
		}

		for {
			select {
			case <-r.Context().Done():
				return
			case line, open := <-ch:
				if !open {
					_, finalStatus, finalCode, _, _, _ := jm.Subscribe(id)
					sendEvent("done", map[string]any{"status": finalStatus, "exit_code": finalCode})
					return
				}
				sendEvent("log", map[string]string{"line": line})
			}
		}
	})

	// Embedded React SPA
	mux.Handle("/", StaticHandler())

	srv := &http.Server{
		Addr:              *listenAddr,
		Handler:           csrfGuard(mux),
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("Conveyor OS Operator Panel v%s listening on http://%s", version, *listenAddr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
}
