/**
 * A JSON body read under a byte ceiling, and nothing else.
 *
 * Every provider Relay talks to answers over a connection Relay does not control, so a response
 * is read as a bounded stream rather than a string: a body that outgrows the ceiling is abandoned
 * and answers as no object at all, which is the same answer a body that is not JSON gets.
 */
export async function readBoundedJSON(
  response: Response,
  maximumBytes: number,
): Promise<Record<string, unknown>> {
  const reader = response.body?.getReader();
  if (!reader) return {};
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maximumBytes) {
      await reader.cancel();
      return {};
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return {};
  }
  return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
    ? (parsed as Record<string, unknown>)
    : {};
}
