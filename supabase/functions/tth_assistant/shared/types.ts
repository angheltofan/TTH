// Shared TypeScript types used across the tth_assistant edge function.
//
// Split from index.ts on 2026-07-10 as part of the modularisation
// refactor. Nothing here changed shape; only the location.

import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";

export interface IncomingMessage {
  role: "user" | "assistant";
  content: string;
}

export interface SuccessResponse {
  reply: string;
  sources: string[];
}

export interface ErrorResponse {
  error: string;
}

export interface OpenAiMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  tool_calls?: Array<{
    id: string;
    type: "function";
    function: { name: string; arguments: string };
  }>;
  tool_call_id?: string;
  name?: string;
}

/// Shape used for every entry of the TOOLS array registered with OpenAI.
export interface ToolDef {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

/// Signature every tool implementation must match. `admin` is the
/// service-role Supabase client (guarded by the outer HTTP handler,
/// which already validated the caller's role).
export type ToolHandler = (
  admin: SupabaseClient,
  args: Record<string, unknown>,
) => Promise<Record<string, unknown>>;

/// Re-export SupabaseClient so tool modules don't need to import it
/// from the CDN URL directly (single source of truth for the version).
export type { SupabaseClient };
