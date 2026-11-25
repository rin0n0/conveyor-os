import { useState } from "react";
import {
  api,
  type JobInfo,
  type PackagesOverview,
  type SearchResult,
} from "../api";
import { ConfirmDialog } from "./ConfirmDialog";

interface PackagesViewProps {
  overview: PackagesOverview | null;
  onRefresh: () => void;
  onJobStarted: (job: JobInfo) => void;
  onError: (msg: string) => void;
}

type TabMode = "catalog" | "installed" | "search";

export function PackagesView({
  overview,
  onRefresh,
  onJobStarted,
  onError,
}: PackagesViewProps) {
  const [tabMode, setTabMode] = useState<TabMode>("catalog");
  const [searchQuery, setSearchQuery] = useState("");
  const [searchResults, setSearchResults] = useState<SearchResult[]>([]);
  const [searching, setSearching] = useState(false);
  const [pendingUninstall, setPendingUninstall] = useState<{
    id: string;
    name: string;
  } | null>(null);

  const handleSearch = async (e: React.FormEvent) => {
    e.preventDefault();
    if (searchQuery.trim().length < 2) return;
    setSearching(true);
    setTabMode("search");
    try {
      const data = await api.searchPackages(searchQuery.trim());
      setSearchResults(data.results);
    } catch (err) {
      onError((err as Error).message);
    } finally {
      setSearching(false);
    }
  };

  const runAction = async (fn: () => Promise<{ job: JobInfo }>) => {
    try {
      const res = await fn();
      onJobStarted(res.job);
    } catch (err) {
      onError((err as Error).message);
    }
  };

  return (
    <>
      <div className="toolbar">
        <div className="btn-group">
          <button
            type="button"
            className={`btn ${tabMode === "catalog" ? "active-filter" : ""}`}
            onClick={() => setTabMode("catalog")}
          >
            Рекомендованные ({overview?.catalog.length ?? 0})
          </button>
          <button
            type="button"
            className={`btn ${tabMode === "installed" ? "active-filter" : ""}`}
            onClick={() => setTabMode("installed")}
          >
            Установленные ({overview?.installed.length ?? 0})
          </button>
          {searchResults.length > 0 && (
            <button
              type="button"
              className={`btn ${tabMode === "search" ? "active-filter" : ""}`}
              onClick={() => setTabMode("search")}
            >
              Поиск ({searchResults.length})
            </button>
          )}
        </div>

        <form className="search-form" onSubmit={handleSearch}>
          <input
            type="search"
            className="input"
            placeholder="Поиск в Flathub (telegram, obsidian, code...)"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            aria-label="Поиск приложений в Flathub"
          />
          <button type="submit" className="btn" disabled={searching}>
            {searching ? "Поиск..." : "Найти"}
          </button>
        </form>

        <div className="btn-group">
          <button
            type="button"
            className={`btn ${overview && overview.update_count > 0 ? "primary" : ""}`}
            onClick={() => runAction(() => api.updatePackage(""))}
          >
            Обновить все{" "}
            {overview && overview.update_count > 0
              ? `(${overview.update_count})`
              : ""}
          </button>
          <button type="button" className="btn" onClick={onRefresh}>
            Обновить список
          </button>
        </div>
      </div>

      {!overview?.flathub_ready && overview !== null && (
        <div className="badge warn">
          Репозиторий Flathub ещё не подключён — он добавится автоматически при первой установке.
        </div>
      )}

      {tabMode === "catalog" && (
        <div className="card-grid">
          {(overview?.catalog ?? []).map((item) => (
            <article key={item.id} className="card">
              <div>
                <div className="card-header">
                  <h2 className="card-title">{item.name}</h2>
                  <span className="badge">{item.category}</span>
                </div>
                <div className="card-meta">{item.id}</div>
              </div>
              <p className="card-desc">{item.description}</p>
              <div className="card-actions">
                <div>
                  {item.installed && (
                    <span className="badge ok">
                      Установлено {item.version || ""}
                    </span>
                  )}
                  {item.has_update && (
                    <span className="badge warn">Обновление {item.new_version}</span>
                  )}
                </div>
                <div className="btn-group">
                  {!item.installed ? (
                    <button
                      type="button"
                      className="btn primary"
                      onClick={() => runAction(() => api.installPackage(item.id))}
                    >
                      Установить
                    </button>
                  ) : (
                    <>
                      {item.has_update && (
                        <button
                          type="button"
                          className="btn success"
                          onClick={() => runAction(() => api.updatePackage(item.id))}
                        >
                          Обновить
                        </button>
                      )}
                      <button
                        type="button"
                        className="btn danger"
                        onClick={() =>
                          setPendingUninstall({ id: item.id, name: item.name })
                        }
                      >
                        Удалить
                      </button>
                    </>
                  )}
                </div>
              </div>
            </article>
          ))}
        </div>
      )}

      {tabMode === "installed" && (
        <div className="section-box">
          <h2 className="section-title">Установленные приложения Flatpak</h2>
          {overview?.installed.length === 0 ? (
            <p className="card-desc">
              Пока ничего не установлено через Flatpak. Выберите приложение во вкладке «Рекомендованные» или через поиск Flathub.
            </p>
          ) : (
            <div className="table-wrap">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>Приложение</th>
                    <th>ID</th>
                    <th>Версия</th>
                    <th>Область</th>
                    <th>Действия</th>
                  </tr>
                </thead>
                <tbody>
                  {(overview?.installed ?? []).map((app) => (
                    <tr key={app.id}>
                      <td>{app.name}</td>
                      <td className="card-meta">{app.id}</td>
                      <td>
                        {app.version}{" "}
                        {app.has_update && (
                          <span className="badge warn">→ {app.new_version}</span>
                        )}
                      </td>
                      <td>{app.installation}</td>
                      <td>
                        <div className="btn-group">
                          {app.has_update && (
                            <button
                              type="button"
                              className="btn success"
                              onClick={() => runAction(() => api.updatePackage(app.id))}
                            >
                              Обновить
                            </button>
                          )}
                          <button
                            type="button"
                            className="btn danger"
                            onClick={() =>
                              setPendingUninstall({ id: app.id, name: app.name })
                            }
                          >
                            Удалить
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      {tabMode === "search" && (
        <div className="section-box">
          <h2 className="section-title">Результаты поиска Flathub</h2>
          {searchResults.length === 0 ? (
            <p className="card-desc">Ничего не найдено по запросу «{searchQuery}».</p>
          ) : (
            <div className="table-wrap">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>Название</th>
                    <th>Описание</th>
                    <th>ID</th>
                    <th>Версия</th>
                    <th>Действие</th>
                  </tr>
                </thead>
                <tbody>
                  {searchResults.map((res) => (
                    <tr key={res.id}>
                      <td>{res.name}</td>
                      <td className="card-desc">{res.description}</td>
                      <td className="card-meta">{res.id}</td>
                      <td>{res.version}</td>
                      <td>
                        {res.installed ? (
                          <span className="badge ok">Установлено</span>
                        ) : (
                          <button
                            type="button"
                            className="btn primary"
                            onClick={() => runAction(() => api.installPackage(res.id))}
                          >
                            Установить
                          </button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      <ConfirmDialog
        open={pendingUninstall !== null}
        title="Удалить приложение?"
        message={`Вы действительно хотите удалить ${pendingUninstall?.name ?? ""} (${pendingUninstall?.id ?? ""})?`}
        confirmLabel="Удалить"
        danger
        onCancel={() => setPendingUninstall(null)}
        onConfirm={() => {
          if (pendingUninstall) {
            const id = pendingUninstall.id;
            setPendingUninstall(null);
            runAction(() => api.uninstallPackage(id));
          }
        }}
      />
    </>
  );
}
