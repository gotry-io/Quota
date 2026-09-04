import assert from "node:assert/strict";
import test from "node:test";
import { renderMarkdown } from "../src/lib/markdown.ts";

test("escapes raw HTML including script tags", () => {
  const html = renderMarkdown("<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>");
  assert.equal(html.includes("<script>"), false);
  assert.equal(html.includes("<img"), false);
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
});

test("rejects javascript: and other non-http(s) links", () => {
  const html = renderMarkdown(
    [
      "[bad](javascript:alert(1))",
      "[data](data:text/html,hi)",
      "[ok](https://github.com/gotry-io/Quota/issues)",
      "[account](/my)",
      "[protocol](//evil.example)",
    ].join("\n\n"),
  );
  assert.equal(html.includes('href="javascript:'), false);
  assert.equal(html.includes('href="data:'), false);
  assert.equal(html.includes('href="//evil.example"'), false);
  assert.match(html, /\[bad\]\(javascript:alert\(1\)\)/);
  assert.match(html, /<a href="https:\/\/github.com\/gotry-io\/Quota\/issues">ok<\/a>/);
  assert.match(html, /<a href="\/my">account<\/a>/);
});

test("renders heading levels one through three and leaves deeper hashes as text", () => {
  const html = renderMarkdown("# One\n\n## Two\n\n### Three\n\n#### Four");
  assert.match(html, /<h1 id="page-title">One<\/h1>/);
  assert.match(html, /<h2>Two<\/h2>/);
  assert.match(html, /<h3>Three<\/h3>/);
  assert.equal(html.includes("<h4>"), false);
  assert.match(html, /<p>#### Four<\/p>/);
});

test("renders lists, bold, inline code, and quotes", () => {
  const html = renderMarkdown("- **bold** item with `code`\n- second\n\n> Draft — pending review");
  assert.match(
    html,
    /<ul><li><strong>bold<\/strong> item with <code>code<\/code><\/li><li>second<\/li><\/ul>/,
  );
  assert.match(html, /<blockquote><p>Draft — pending review<\/p><\/blockquote>/);
});
