import { useCallback, useEffect, useState } from "react";
import {
  api,
  subscribeJob,
  type JobInfo,
  type ModelsOverview,
  type PackagesOverview,
  type SystemStatus,
} from "./api";
import { JobsDrawer } from "./components/JobsDrawer";
import { ModelsView } from "./components/ModelsView";
import { PackagesView } from "./components/PackagesView";

type Section = "packages" | "models";

export function App() {
  const [section, setSection] = useState<Section>("packages");
  const [system, setSystem] = useState<SystemStatus | null>(null);
  const [pkgOverview, setPkgOverview] = useState<PackagesOverview | null>(null);
  const [modelsOverview, setModelsOverview] = useState<ModelsOverview | null>(null);
  const [jobs, setJobs] = useState<JobInfo[]>([]);
  const [activeJobId, setActiveJobId] = useState<string | null>(null);
  const [drawerCollapsed, setDrawerCollapsed] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const loadSystem = useCallback(async () => {
    try {
      setSystem(await api.getSystem());
    } catch {
      // System banner refreshes silently
    }
  }, []);

  const loadPackages = useCallback(async () => {
    try {
      setPkgOverview(await api.getPackages());
    } catch (err) {
      setErrorMsg((err as Error).message);
    }
  }, []);

  const loadModels = useCallback(async () => {
    try {
      setModelsOverview(await api.getModels());
    } catch (err) {
      setErrorMsg((err as Error).message);
    }
  }, []);

  useEffect(() => {
    loadSystem();
    loadPackages();
    loadModels();
    api.getJobs().then((res) => setJobs(res.jobs)).catch(() => {});
    const timer = window.setInterval(loadSystem, 5000);
    return () => window.clearInterval(timer);
  }, [loadSystem, loadPackages, loadModels]);

  const handleJobStarted = (job: JobInfo) => {
    setErrorMsg(null);
    setJobs((prev) => [job, ...prev.filter((j) => j.id !== job.id)]);
    setActiveJobId(job.id);
    setDrawerCollapsed(false);

    subscribeJob(
      job.id,
      (line) => {
        setJobs((prev) =>
          prev.map((j) =>
            j.id === job.id ? { ...j, logs: [...j.logs, line] } : j,
          ),
        );
      },
      (status, exitCode) => {
        setJobs((prev) =>
          prev.map((j) =>
            j.id === job.id ? { ...j, status, exit_code: exitCode } : j,
          ),
        );
        loadPackages();
        loadModels();
        loadSystem();
      },
    );
  };

  const runningCount = jobs.filter((j) => j.status === "running").length;

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand">
          <div>
            <h1 className="brand-title">Conveyor OS — Панель оператора</h1>
            <div className="brand-subtitle">
              {system ? `${system.username}@${system.hostname}` : "127.0.0.1:7070"}
            </div>
          </div>
        </div>

        <div className="sys-badges">
          <span className={`badge ${system?.gpu_backend === "cuda" ? "ok" : ""}`}>
            GPU: {system?.gpu_backend?.toUpperCase() ?? "…"}
            {system?.gpu_name ? ` (${system.gpu_name})` : ""}
          </span>
          <span className="badge">
            VRAM:{" "}
            {system && system.vram_total_mib > 0
              ? `${(system.vram_used_mib / 1024).toFixed(1)}/${(system.vram_total_mib / 1024).toFixed(1)} ГиБ`
              : `${system?.vram_gib ?? 0} ГиБ`}
          </span>
          <span className="badge">RAM: {system?.ram_gib ?? "—"} ГиБ</span>
          <span className={`badge ${system?.llama_swap_online ? "ok" : "warn"}`}>
            API :8080 {system?.llama_swap_online ? "OK" : "Offline"}
          </span>
        </div>
      </header>

      <nav className="main-nav" aria-label="Разделы панели">
        <button
          type="button"
          className="nav-btn"
          aria-current={section === "packages" ? "page" : undefined}
          onClick={() => setSection("packages")}
        >
          Пакеты (Flatpak)
          {pkgOverview && pkgOverview.update_count > 0 && (
            <span className="badge warn">{pkgOverview.update_count}</span>
          )}
        </button>
        <button
          type="button"
          className="nav-btn"
          aria-current={section === "models" ? "page" : undefined}
          onClick={() => setSection("models")}
        >
          Модели и ИИ
        </button>
        {runningCount > 0 && (
          <span className="badge warn" style={{ marginLeft: "auto" }}>
            Выполняется задач: {runningCount}
          </span>
        )}
      </nav>

      <main className="main-content">
        {errorMsg && (
          <div className="alert-err" role="alert">
            Ошибка: {errorMsg}
          </div>
        )}

        {section === "packages" ? (
          <PackagesView
            overview={pkgOverview}
            onRefresh={loadPackages}
            onJobStarted={handleJobStarted}
            onError={setErrorMsg}
          />
        ) : (
          <ModelsView
            overview={modelsOverview}
            system={system}
            onRefresh={loadModels}
            onJobStarted={handleJobStarted}
            onError={setErrorMsg}
          />
        )}
      </main>

      <JobsDrawer
        jobs={jobs}
        activeJobId={activeJobId}
        onSelectJob={setActiveJobId}
        collapsed={drawerCollapsed}
        onToggleCollapse={() => setDrawerCollapsed((c) => !c)}
      />
    </div>
  );
}
