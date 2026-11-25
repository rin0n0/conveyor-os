import { useState } from "react";
import {
  api,
  formatBytes,
  type JobInfo,
  type ModelsOverview,
  type SystemStatus,
  type WeightFile,
} from "../api";

interface ModelsViewProps {
  overview: ModelsOverview | null;
  system: SystemStatus | null;
  onRefresh: () => void;
  onJobStarted: (job: JobInfo) => void;
  onError: (msg: string) => void;
}

export function ModelsView({
  overview,
  system,
  onRefresh,
  onJobStarted,
  onError,
}: ModelsViewProps) {
  const [selectedRole, setSelectedRole] = useState<Record<string, string>>({});
  const [selectedMode, setSelectedMode] = useState<Record<string, "link" | "copy">>({});
  const [dlUrl, setDlUrl] = useState("");
  const [dlDest, setDlDest] = useState<"shared" | "local">("shared");
  const [dlRole, setDlRole] = useState("coder");

  const defaultRoleForFile = (wf: WeightFile): string => {
    if (selectedRole[wf.path]) return selectedRole[wf.path];
    return wf.ext === ".gguf" ? "coder" : "comfy-checkpoint";
  };

  const handleAssign = async (wf: WeightFile) => {
    const role = defaultRoleForFile(wf);
    const mode = selectedMode[wf.path] ?? "link";
    try {
      const res = await api.assignModel(wf.path, role, mode);
      if (res.job) {
        onJobStarted(res.job);
      } else {
        onRefresh();
      }
    } catch (err) {
      onError((err as Error).message);
    }
  };

  const handleUnassign = async (role: string) => {
    try {
      await api.unassignRole(role);
      onRefresh();
    } catch (err) {
      onError((err as Error).message);
    }
  };

  const handleUnload = async () => {
    try {
      await api.unloadModels();
      onRefresh();
    } catch (err) {
      onError((err as Error).message);
    }
  };

  const handleDownload = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!dlUrl.trim()) return;
    try {
      const res = await api.downloadModel(dlUrl.trim(), dlDest, dlRole);
      setDlUrl("");
      onJobStarted(res.job);
    } catch (err) {
      onError((err as Error).message);
    }
  };

  return (
    <>
      <div className="toolbar">
        <div className="btn-group">
          <span
            className={`badge ${system?.llama_swap_online ? "ok" : "err"}`}
          >
            llama-swap (:8080): {system?.llama_swap_online ? "онлайн" : "не запущен"}
          </span>
          {system?.llama_profile && (
            <span className="badge">
              Профиль: {system.llama_profile.split("/").pop()}
            </span>
          )}
        </div>
        <div className="btn-group">
          <button
            type="button"
            className="btn warn"
            onClick={handleUnload}
            disabled={!system?.llama_swap_online}
          >
            Выгрузить все из VRAM
          </button>
          <button type="button" className="btn" onClick={onRefresh}>
            Сканировать диски
          </button>
        </div>
      </div>

      <section className="section-box">
        <h2 className="section-title">Активные роли LLM (маршрутизация llama-swap)</h2>
        <div className="card-grid">
          {(overview?.roles ?? []).map((r) => (
            <article key={r.role} className="card">
              <div>
                <div className="card-header">
                  <h3 className="card-title">{r.label}</h3>
                  {r.assigned ? (
                    <span className={`badge ${r.broken ? "err" : "ok"}`}>
                      {r.broken ? "Битая ссылка" : formatBytes(r.size_bytes)}
                    </span>
                  ) : (
                    <span className="badge">Не назначена</span>
                  )}
                </div>
                <p className="card-desc">{r.description}</p>
              </div>
              <div className="card-meta">
                {r.assigned ? `${r.file_name} (${r.target_path})` : "—"}
              </div>
              <div className="card-actions">
                <span className="card-meta">API: model=&quot;{r.role}&quot;</span>
                {r.assigned && (
                  <button
                    type="button"
                    className="btn danger"
                    onClick={() => handleUnassign(r.role)}
                  >
                    Отвязать
                  </button>
                )}
              </div>
            </article>
          ))}
        </div>
      </section>

      <section className="section-box">
        <h2 className="section-title">Скачать модель по прямой ссылке (HuggingFace GGUF / Safetensors)</h2>
        <form className="form-grid" onSubmit={handleDownload}>
          <label className="field" style={{ gridColumn: "span 2" }}>
            Прямой URL файла (.gguf или .safetensors)
            <input
              type="url"
              className="input"
              required
              placeholder="https://huggingface.co/.../resolve/main/model-Q4_K_M.gguf"
              value={dlUrl}
              onChange={(e) => setDlUrl(e.target.value)}
            />
          </label>
          <label className="field">
            Куда сохранить
            <select
              className="select"
              value={dlDest}
              onChange={(e) => setDlDest(e.target.value as "shared" | "local")}
            >
              <option value="shared">Диск E: (/mnt/shared/models)</option>
              <option value="local">Системный @models (/var/lib/models)</option>
            </select>
          </label>
          <label className="field">
            Назначить роль сразу
            <select
              className="select"
              value={dlRole}
              onChange={(e) => setDlRole(e.target.value)}
            >
              <option value="coder">coder (код)</option>
              <option value="fast">fast (чат)</option>
              <option value="think">think (рассуждения)</option>
              <option value="embed">embed (RAG)</option>
              <option value="comfy-checkpoint">ComfyUI Checkpoint</option>
              <option value="comfy-lora">ComfyUI LoRA</option>
              <option value="">Не назначать</option>
            </select>
          </label>
          <button type="submit" className="btn primary">
            Скачать и подключить
          </button>
        </form>
      </section>

      <section className="section-box">
        <h2 className="section-title">
          Найденные веса на диске (/mnt/shared, ~/Downloads, /var/lib/models)
        </h2>
        {(overview?.discovered_files.length ?? 0) === 0 ? (
          <p className="card-desc">
            Файлы весов (.gguf, .safetensors, .ckpt) не найдены. Скачайте модель выше или положите её на диск E:\models\ в Windows.
          </p>
        ) : (
          <div className="table-wrap">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Файл</th>
                  <th>Размер</th>
                  <th>Расположение</th>
                  <th>Подключение к роли</th>
                </tr>
              </thead>
              <tbody>
                {(overview?.discovered_files ?? []).map((wf) => {
                  const role = defaultRoleForFile(wf);
                  const mode = selectedMode[wf.path] ?? "link";
                  return (
                    <tr key={wf.path}>
                      <td>
                        <div>{wf.name}</div>
                        <div className="card-meta">{wf.path}</div>
                      </td>
                      <td>{formatBytes(wf.size_bytes)}</td>
                      <td>{wf.location}</td>
                      <td>
                        <div className="assign-row">
                          <select
                            className="select"
                            aria-label={`Роль для ${wf.name}`}
                            value={role}
                            onChange={(e) =>
                              setSelectedRole((prev) => ({
                                ...prev,
                                [wf.path]: e.target.value,
                              }))
                            }
                          >
                            {wf.ext === ".gguf" ? (
                              <>
                                <option value="coder">coder (код)</option>
                                <option value="fast">fast (чат)</option>
                                <option value="think">think (логика)</option>
                                <option value="embed">embed (RAG)</option>
                              </>
                            ) : (
                              <>
                                <option value="comfy-checkpoint">ComfyUI Checkpoint</option>
                                <option value="comfy-lora">ComfyUI LoRA</option>
                              </>
                            )}
                          </select>
                          <select
                            className="select"
                            aria-label={`Способ подключения ${wf.name}`}
                            value={mode}
                            onChange={(e) =>
                              setSelectedMode((prev) => ({
                                ...prev,
                                [wf.path]: e.target.value as "link" | "copy",
                              }))
                            }
                          >
                            <option value="link">Симлинк</option>
                            <option value="copy">Копия</option>
                          </select>
                          <button
                            type="button"
                            className="btn primary"
                            onClick={() => handleAssign(wf)}
                          >
                            Подключить
                          </button>
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {((overview?.comfy.checkpoints.length ?? 0) > 0 ||
        (overview?.comfy.loras.length ?? 0) > 0) && (
        <section className="section-box">
          <h2 className="section-title">Модели ComfyUI</h2>
          <div className="card-grid">
            <div className="card">
              <h3 className="card-title">Checkpoints ({overview?.comfy.checkpoints.length ?? 0})</h3>
              {(overview?.comfy.checkpoints ?? []).map((c) => (
                <div key={c.path} className="card-meta">
                  • {c.name} ({formatBytes(c.size_bytes)})
                </div>
              ))}
            </div>
            <div className="card">
              <h3 className="card-title">LoRAs ({overview?.comfy.loras.length ?? 0})</h3>
              {(overview?.comfy.loras ?? []).map((l) => (
                <div key={l.path} className="card-meta">
                  • {l.name} ({formatBytes(l.size_bytes)})
                </div>
              ))}
            </div>
          </div>
        </section>
      )}
    </>
  );
}
