// HTTP client wrapping the Design Canvas Swift app API on localhost:7420.
// Every method returns a typed result or throws — callers handle errors via mapFetchError.
// Auth token is read from ~/.designcanvas/api_token (created by the macOS app on first launch).

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Read per-call so tests can redirect to an unreachable URL for ghost-response audits.
export function getBaseUrl(): string {
  const url = new URL(process.env.DESIGN_CANVAS_URL ?? "http://localhost:7420");
  if (!["localhost", "127.0.0.1", "[::1]"].includes(url.hostname) ||
      !["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new Error("DESIGN_CANVAS_URL must be a loopback HTTP URL; local credentials cannot be sent to a remote host.");
  }
  return url.origin;
}

/** Read the auth token from the shared file, or fall back to env var. */
function loadAuthToken(): string {
  // Environment variable override (for testing or custom setups)
  if (process.env.DESIGN_CANVAS_TOKEN) {
    return process.env.DESIGN_CANVAS_TOKEN;
  }

  const tokenPath = getTokenPath();
  try {
    return readFileSync(tokenPath, "utf-8").trim();
  } catch {
    // Token file not found — app may not have been launched yet
    return "";
  }
}

export function getTokenPath(): string {
  return process.env.DESIGN_CANVAS_TOKEN_FILE ?? join(homedir(), process.env.DESIGN_CANVAS_PROFILE === "local" ? ".designcanvas-local" : ".designcanvas", "api_token");
}

export interface RouteData {
  id: string;
  path: string;
  x: number;
  y: number;
  width: number;
  height: number;
  status?: "active" | "removed";
  screenshotPath?: string;
  // C0: which dev server this route is plugged into. Present only on multi-server canvases.
  serverId?: string;
  serverPort?: number;
  serverProject?: string;
}

export interface AddRouteResult {
  ok: boolean;
  path: string;
  id: string;
}

export interface ServerData {
  serverId: string;
  port?: number;
  projectName: string;
  projectDir?: string;
  status: "connected" | "stale" | "offline";
  origin: string;
  isPrimary: boolean;
}

export interface ServerListResult {
  servers: ServerData[];
}

export interface AvailableServer {
  serverId: string;
  port?: number;
  projectName: string;
  projectDir?: string;
}

export interface ServerDisambiguationError {
  error: "server_required";
  message: string;
  availableServers: AvailableServer[];
}

export interface CaptureResult {
  screenshots: Array<{ path: string; filePath: string }>;
  // Present only when the server hit its 180s budget and returned what completed.
  // Caller should treat the call as a soft failure and surface the diagnostic.
  error?: string;
  captured?: number;
  total?: number;
  unsettled?: string[];
}

export interface DocumentData {
  id: string;
  filePath: string;
  /** "markdown" for .md/.markdown, "html" for .html/.htm. Derived from extension server-side. */
  kind: "markdown" | "html";
  x: number;
  y: number;
  width: number;
  height: number;
  displayName?: string;
}

export interface AddFileResult {
  ok: boolean;
  filePath: string;
  id: string;
}

export interface ImageData {
  id: string;
  filePath: string;
  x: number;
  y: number;
  width: number;
  height: number;
  displayName?: string;
}

async function request<T>(
  path: string,
  options: RequestInit = {},
  timeoutMs = 30_000,
  allowStatus: number[] = []
): Promise<T> {
  const baseUrl = getBaseUrl();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  // Merge auth header into every request
  const headers: Record<string, string> = {
    ...(options.headers as Record<string, string> ?? {}),
  };
  const authToken = loadAuthToken();
  if (authToken) {
    headers["Authorization"] = `Bearer ${authToken}`;
  }

  try {
    const res = await fetch(`${baseUrl}${path}`, {
      ...options,
      headers,
      signal: controller.signal,
    });

    // `allowStatus` lets the caller surface specific non-2xx responses as data instead
    // of structured errors (e.g. /capture returns a 504 with partial screenshots).
    if (!res.ok && !allowStatus.includes(res.status)) {
      const body = await res.text().catch(() => "");
      const { mapHttpError } = await import("./errors.js");
      const err = mapHttpError(res.status, res.statusText, body);
      throw Object.assign(new Error(err.content[0].type === "text" ? err.content[0].text : ""), {
        mcpResult: err,
      });
    }

    return (await res.json()) as T;
  } finally {
    clearTimeout(timer);
  }
}

export async function listRoutes(): Promise<RouteData[]> {
  return request<RouteData[]>("/routes");
}

export type Placement = "right-of-last" | "new-row";

export async function addRoute(params: {
  path: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  port?: number;
  serverId?: string;
  placement?: Placement;
}): Promise<AddRouteResult | ServerDisambiguationError> {
  return request<AddRouteResult | ServerDisambiguationError>(
    "/routes",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(params),
    },
    30_000,
    [409] // surface structured disambiguation body to the caller
  );
}

export async function listServers(): Promise<ServerData[]> {
  const result = await request<ServerListResult>("/servers");
  return result.servers;
}

export async function removeRoute(params: {
  id?: string;
  path?: string;
}): Promise<{ ok: boolean }> {
  const query = params.id
    ? `id=${encodeURIComponent(params.id)}`
    : `path=${encodeURIComponent(params.path!)}`;

  return request<{ ok: boolean }>(`/routes?${query}`, {
    method: "DELETE",
  });
}

export async function updateRoute(params: {
  id: string;
  newPath: string;
}): Promise<{ ok: boolean; id: string; path: string }> {
  return request<{ ok: boolean; id: string; path: string }>("/routes", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id: params.id, path: params.newPath }),
  });
}

export async function captureCanvas(ids?: string[]): Promise<CaptureResult> {
  const hasIds = Array.isArray(ids) && ids.length > 0;
  return request<CaptureResult>(
    "/capture",
    {
      method: "POST",
      ...(hasIds
        ? {
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ ids }),
          }
        : {}),
    },
    200_000, // 200s — exceeds Swift's 180s capture timeout
    [504]    // surface partial-result 504 body to the caller as data
  );
}

// --- Markdown documents -----------------------------------------------------

export async function listDocuments(): Promise<DocumentData[]> {
  return request<DocumentData[]>("/documents");
}

export async function addDocument(params: {
  filePath: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  placement?: Placement;
}): Promise<AddFileResult> {
  return request<AddFileResult>("/documents", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(params),
  });
}

export async function removeDocument(params: { id: string }): Promise<{ ok: boolean }> {
  return request<{ ok: boolean }>(
    `/documents?id=${encodeURIComponent(params.id)}`,
    { method: "DELETE" }
  );
}

// --- Images -----------------------------------------------------------------

export async function listImages(): Promise<ImageData[]> {
  return request<ImageData[]>("/images");
}

export async function addImage(params: {
  filePath: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  placement?: Placement;
}): Promise<AddFileResult> {
  return request<AddFileResult>("/images", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(params),
  });
}

export async function removeImage(params: { id: string }): Promise<{ ok: boolean }> {
  return request<{ ok: boolean }>(
    `/images?id=${encodeURIComponent(params.id)}`,
    { method: "DELETE" }
  );
}

// --- Batch -----------------------------------------------------------------

export type BatchItem =
  | { type: "route"; path: string; width?: number; height?: number; port?: number; serverId?: string }
  | { type: "document"; filePath: string; width?: number; height?: number }
  | { type: "image"; filePath: string; width?: number; height?: number };

export type BatchLayout = "row" | "pairs-rows";

export interface AddedFrame {
  id: string;
  type: "route" | "document" | "image";
  x: number;
  y: number;
  width: number;
  height: number;
  path?: string;
  filePath?: string;
}

export interface AddFramesResult {
  ok: boolean;
  added: AddedFrame[];
}

export async function addFrames(params: {
  items: BatchItem[];
  layout?: BatchLayout;
  placement?: Placement;
}): Promise<AddFramesResult | ServerDisambiguationError> {
  return request<AddFramesResult | ServerDisambiguationError>(
    "/frames/batch",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(params),
    },
    60_000,
    [409]
  );
}

// --- Sections ---------------------------------------------------------------

export interface SectionData {
  id: string;
  title: string;
  x: number;
  y: number;
  width: number;
  height: number;
  routeIds: string[];
  documentIds: string[];
  imageIds: string[];
}

export interface AddSectionResult {
  ok: boolean;
  sectionId: string;
  added: AddedFrame[];
}

export async function listSections(): Promise<SectionData[]> {
  return request<SectionData[]>("/sections");
}

export async function addSection(params: {
  title: string;
  items: BatchItem[];
  layout?: BatchLayout;
  x?: number;
  y?: number;
}): Promise<AddSectionResult | ServerDisambiguationError> {
  return request<AddSectionResult | ServerDisambiguationError>(
    "/sections",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(params),
    },
    60_000,
    [409]
  );
}

export async function removeSection(params: { id: string }): Promise<{ ok: boolean }> {
  return request<{ ok: boolean }>(
    `/sections?id=${encodeURIComponent(params.id)}`,
    { method: "DELETE" }
  );
}
