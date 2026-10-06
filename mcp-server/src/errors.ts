// Structured MCP error responses. Never throw from tool handlers — always return
// { content: [...], isError: true } so the agent gets a helpful message, not a crash.

export interface McpToolResult {
  [key: string]: unknown;
  content: Array<{ type: "text"; text: string } | { type: "image"; data: string; mimeType: string }>;
  isError?: boolean;
}

export function errorResult(message: string): McpToolResult {
  return {
    content: [{ type: "text", text: message }],
    isError: true,
  };
}

export function textResult(text: string): McpToolResult {
  return {
    content: [{ type: "text", text }],
  };
}

export function mapFetchError(error: unknown): McpToolResult {
  if (error instanceof TypeError && error.message.includes("fetch failed")) {
    const cause = (error as { cause?: { code?: string } }).cause;
    if (cause?.code === "ECONNREFUSED" || cause?.code === "ECONNRESET") {
      return errorResult(
        "Design Canvas is not running. Please open the Design Canvas Mac app first. " +
          "The app must be running for these tools to work."
      );
    }
  }

  if (error instanceof DOMException && error.name === "AbortError") {
    return errorResult(
      "Request to Design Canvas timed out. The capture may have too many routes."
    );
  }

  if (error instanceof SyntaxError) {
    return errorResult(
      "Invalid response from Design Canvas API. The app may be in a bad state."
    );
  }

  const msg = error instanceof Error ? error.message : String(error);
  return errorResult(`Unexpected error communicating with Design Canvas: ${msg}`);
}

export function mapHttpError(status: number, statusText: string, body: string): McpToolResult {
  switch (status) {
    case 400:
      return errorResult(`Invalid parameters: ${body}`);
    case 404:
      return errorResult("Route not found on the canvas.");
    case 500:
      return errorResult("Design Canvas encountered an error. Try again or restart the app.");
    case 504: {
      // Try the structured timeout body shipped in PR 2: { captured, total, unsettled }.
      // Falls back to the older message when the body isn't structured.
      try {
        const parsed = JSON.parse(body) as {
          captured?: number;
          total?: number;
          unsettled?: string[];
        };
        if (typeof parsed.captured === "number" && typeof parsed.total === "number") {
          const unsettled = parsed.unsettled ?? [];
          const head = unsettled.slice(0, 3).join(", ");
          const more = unsettled.length > 3 ? ", …" : "";
          return errorResult(
            `Capture timed out (Design Canvas 180s budget). ${parsed.captured}/${parsed.total} routes captured; ${unsettled.length} did not finish loading: ${head}${more}. Try a smaller subset via \`ids\`, or ensure those routes don't require auth.`,
          );
        }
      } catch {
        // fall through
      }
      return errorResult("Capture timed out. The canvas may have too many routes to capture at once. Open Design Canvas to investigate.");
    }
    default:
      return errorResult(`Design Canvas API returned HTTP ${status}: ${statusText}`);
  }
}
