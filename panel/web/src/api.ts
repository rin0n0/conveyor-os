export interface SystemStatus {
  hostname: string;
  username: string;
  gpu_backend: string;
  gpu_name?: string;
  vram_gib: number;
  vram_used_mib: number;
  vram_total_mib: number;
  ram_gib: number;
  llama_devices: string;
  llama_profile: string;
  llama_swap_online: boolean;
  llama_swap_models: string[];
}

export interface CatalogItem {
  id: string;
  name: string;
  category: string;
  description: string;
  installed: boolean;
  version?: string;
  has_update: boolean;
  new_version?: string;
}

export interface InstalledApp {
  id: string;
  name: string;
  version: string;
  origin: string;
  installation: string;
  has_update: boolean;
  new_version?: string;
}

export interface PackagesOverview {
  flathub_ready: boolean;
  catalog: CatalogItem[];
  installed: InstalledApp[];
  update_count: number;
}

export interface SearchResult {
  id: string;
  name: string;
  description: string;
  version: string;
  remotes: string;
  installed: boolean;
}

export interface RoleInfo {
  role: string;
  label: string;
  description: string;
  assigned: boolean;
  broken: boolean;
  target_path?: string;
  file_name?: string;
  size_bytes?: number;
}

export interface WeightFile {
  name: string;
  path: string;
  size_bytes: number;
  ext: string;
  location: string;
}

export interface ModelsOverview {
  roles: RoleInfo[];
  discovered_files: WeightFile[];
  comfy: {
    checkpoints: WeightFile[];
    loras: WeightFile[];
  };
}

export interface JobInfo {
  id: string;
  title: string;
  status: "running" | "done" | "failed";
  exit_code: number;
  started_at: string;
  finished_at?: string;
  logs: string[];
}

async function request<T>(url: string, init?: RequestInit): Promise<T> {
  const resp = await fetch(url, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    throw new Error((data as { error?: string }).error || `HTTP ${resp.status}`);
  }
  return data as T;
}

export const api = {
  getSystem: () => request<SystemStatus>("/api/system"),
  getPackages: () => request<PackagesOverview>("/api/packages"),
  searchPackages: (q: string) =>
    request<{ results: SearchResult[] }>(`/api/packages/search?q=${encodeURIComponent(q)}`),
  installPackage: (id: string) =>
    request<{ job: JobInfo }>("/api/packages/install", {
      method: "POST",
      body: JSON.stringify({ id }),
    }),
  updatePackage: (id = "") =>
    request<{ job: JobInfo }>("/api/packages/update", {
      method: "POST",
      body: JSON.stringify({ id }),
    }),
  uninstallPackage: (id: string) =>
    request<{ job: JobInfo }>("/api/packages/uninstall", {
      method: "POST",
      body: JSON.stringify({ id }),
    }),
  getModels: () => request<ModelsOverview>("/api/models"),
  assignModel: (path: string, role: string, mode: "link" | "copy") =>
    request<{ ok?: boolean; job?: JobInfo; overview?: ModelsOverview }>("/api/models/assign", {
      method: "POST",
      body: JSON.stringify({ path, role, mode }),
    }),
  unassignRole: (role: string) =>
    request<{ ok: boolean; overview: ModelsOverview }>(`/api/models/role/${encodeURIComponent(role)}`, {
      method: "DELETE",
    }),
  unloadModels: () => request<{ ok: boolean }>("/api/models/unload", { method: "POST" }),
  downloadModel: (url: string, dest: "shared" | "local", role: string) =>
    request<{ job: JobInfo }>("/api/models/download", {
      method: "POST",
      body: JSON.stringify({ url, dest, role }),
    }),
  getJobs: () => request<{ jobs: JobInfo[] }>("/api/jobs"),
};

export function subscribeJob(
  id: string,
  onLog: (line: string) => void,
  onDone: (status: "done" | "failed", exitCode: number) => void,
): () => void {
  const es = new EventSource(`/api/jobs/${encodeURIComponent(id)}/stream`);
  es.addEventListener("log", (ev) => {
    try {
      const parsed = JSON.parse((ev as MessageEvent).data) as { line: string };
      onLog(parsed.line);
    } catch {
      // Ignore malformed chunk
    }
  });
  es.addEventListener("done", (ev) => {
    try {
      const parsed = JSON.parse((ev as MessageEvent).data) as {
        status: "done" | "failed";
        exit_code: number;
      };
      onDone(parsed.status, parsed.exit_code);
    } catch {
      onDone("done", 0);
    }
    es.close();
  });
  es.onerror = () => {
    es.close();
  };
  return () => es.close();
}

export function formatBytes(bytes?: number): string {
  if (!bytes || bytes <= 0) return "—";
  const units = ["Б", "КиБ", "МиБ", "ГиБ"];
  let idx = 0;
  let val = bytes;
  while (val >= 1024 && idx < units.length - 1) {
    val /= 1024;
    idx++;
  }
  return `${val.toFixed(idx >= 2 ? 1 : 0)} ${units[idx]}`;
}
