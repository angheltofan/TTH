// OpenAI chat completion wrapper. The model + temperature live here so
// tuning them (or switching model) is a one-file change.

import { OpenAiMessage, ToolDef } from "../shared/types.ts";

export async function callOpenAi(
  apiKey: string,
  messages: OpenAiMessage[],
  tools: ToolDef[],
): Promise<OpenAiMessage> {
  const body = {
    model: "gpt-4o-mini",
    temperature: 0.2,
    messages,
    tools: tools.map((t) => ({
      type: "function",
      function: {
        name: t.name,
        description: t.description,
        parameters: t.parameters,
      },
    })),
  };
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`OpenAI ${res.status}: ${text.slice(0, 300)}`);
  }
  const json = (await res.json()) as {
    choices?: Array<{ message: OpenAiMessage }>;
  };
  const msg = json.choices?.[0]?.message;
  if (!msg) throw new Error("OpenAI returned no message");
  return msg;
}
