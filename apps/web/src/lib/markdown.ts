const PLACEHOLDER = "\uE000";

export function renderMarkdown(source: string): string {
  const lines = source.replaceAll("\r\n", "\n").replaceAll("\r", "\n").split("\n");
  const html: string[] = [];
  let index = 0;
  let assignedPageTitle = false;

  while (index < lines.length) {
    const line = lines[index];
    if (line === undefined) break;
    if (line.trim() === "") {
      index += 1;
      continue;
    }

    const heading = /^(#{1,3})[ \t]+(.+?)\s*$/.exec(line);
    if (heading?.[1] && heading[2] !== undefined) {
      const level = heading[1].length;
      const slug = headingSlug(heading[2]);
      let id = "";
      if (level === 1 && !assignedPageTitle) {
        id = ' id="page-title"';
        assignedPageTitle = true;
      } else if (slug) {
        id = ` id="${escapeAttribute(slug)}"`;
      }
      html.push(`<h${level}${id}>${renderInline(heading[2])}</h${level}>`);
      index += 1;
      continue;
    }

    if (isQuoteLine(line)) {
      const quoted: string[] = [];
      while (index < lines.length) {
        const current = lines[index];
        if (current === undefined || !isQuoteLine(current)) break;
        quoted.push(stripQuotePrefix(current));
        index += 1;
      }
      html.push(`<blockquote><p>${renderInline(quoted.join(" "))}</p></blockquote>`);
      continue;
    }

    if (line.startsWith("- ")) {
      const items: string[] = [];
      while (index < lines.length) {
        const current = lines[index];
        if (current === undefined || !current.startsWith("- ")) break;
        items.push(`<li>${renderInline(current.slice(2))}</li>`);
        index += 1;
      }
      html.push(`<ul>${items.join("")}</ul>`);
      continue;
    }

    const paragraph: string[] = [];
    while (index < lines.length) {
      const current = lines[index];
      if (
        current === undefined ||
        current.trim() === "" ||
        /^(#{1,3})[ \t]+/.test(current) ||
        current.startsWith("- ") ||
        isQuoteLine(current)
      ) {
        break;
      }
      paragraph.push(current);
      index += 1;
    }
    html.push(`<p>${renderInline(paragraph.join(" "))}</p>`);
  }

  return html.join("");
}

function renderInline(source: string): string {
  const parts: string[] = [];
  const protect = (html: string): string => {
    const token = `${PLACEHOLDER}${parts.length}${PLACEHOLDER}`;
    parts.push(html);
    return token;
  };

  let text = source.replace(/`([^`]+)`/g, (_match, code: string) =>
    protect(`<code>${escapeHtml(code)}</code>`),
  );

  text = text.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (match, label: string, href: string) => {
    if (!isAllowedHref(href)) return match;
    return protect(`<a href="${escapeAttribute(href)}">${escapeHtml(label)}</a>`);
  });

  text = text.replace(/\*\*([^*]+)\*\*/g, (_match, inner: string) =>
    protect(`<strong>${escapeHtml(inner)}</strong>`),
  );

  text = escapeHtml(text);
  return text.replace(
    new RegExp(`${PLACEHOLDER}(\\d+)${PLACEHOLDER}`, "g"),
    (_match, index: string) => parts[Number(index)] ?? "",
  );
}

function isAllowedHref(href: string): boolean {
  if (href.length === 0 || href !== href.trim()) return false;
  if (/[\u0000-\u001F\u007F]/.test(href)) return false;
  if (href.startsWith("/") && !href.startsWith("//")) {
    return !/[:\\]/.test(href);
  }
  try {
    const url = new URL(href);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

function headingSlug(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function isQuoteLine(line: string): boolean {
  return line === ">" || line.startsWith("> ");
}

function stripQuotePrefix(line: string): string {
  return line.startsWith("> ") ? line.slice(2) : "";
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function escapeAttribute(value: string): string {
  return escapeHtml(value).replaceAll("'", "&#39;");
}
