import { useEffect, useRef } from "react";
import type { JobInfo } from "../api";

interface JobsDrawerProps {
  jobs: JobInfo[];
  activeJobId: string | null;
  onSelectJob: (id: string) => void;
  collapsed: boolean;
  onToggleCollapse: () => void;
}

export function JobsDrawer({
  jobs,
  activeJobId,
  onSelectJob,
  collapsed,
  onToggleCollapse,
}: JobsDrawerProps) {
  const logRef = useRef<HTMLPreElement>(null);
  const current = jobs.find((j) => j.id === activeJobId) ?? jobs[0] ?? null;

  useEffect(() => {
    if (!collapsed && logRef.current) {
      logRef.current.scrollTop = logRef.current.scrollHeight;
    }
  }, [current?.logs.length, collapsed]);

  if (jobs.length === 0) {
    return null;
  }

  return (
    <aside className="jobs-drawer" aria-label="Журнал фоновых операций">
      <div className="jobs-header">
        <div className="btn-group">
          <strong>Операции ({jobs.length})</strong>
          {current && (
            <span
              className={`badge ${
                current.status === "done"
                  ? "ok"
                  : current.status === "failed"
                    ? "err"
                    : "warn"
              }`}
            >
              {current.title} —{" "}
              {current.status === "running"
                ? "выполняется..."
                : current.status === "done"
                  ? "готово"
                  : `ошибка (${current.exit_code})`}
            </span>
          )}
        </div>
        <button type="button" className="btn" onClick={onToggleCollapse}>
          {collapsed ? "Показать лог" : "Свернуть лог"}
        </button>
      </div>

      {!collapsed && (
        <>
          {jobs.length > 1 && (
            <div className="jobs-tabs">
              {jobs.slice(0, 6).map((j) => (
                <button
                  key={j.id}
                  type="button"
                  className={`btn ${j.id === current?.id ? "active-filter" : ""}`}
                  onClick={() => onSelectJob(j.id)}
                >
                  {j.status === "running" ? "⏳" : j.status === "done" ? "✓" : "✕"}{" "}
                  {j.title}
                </button>
              ))}
            </div>
          )}
          <pre ref={logRef} className="log-console">
            {current && current.logs.length > 0
              ? current.logs.join("\n")
              : "Ожидание вывода..."}
          </pre>
        </>
      )}
    </aside>
  );
}
