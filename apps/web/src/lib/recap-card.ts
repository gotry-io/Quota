import { SHARE_CARD_HEIGHT, SHARE_CARD_WIDTH } from "./share-card.ts";

/**
 * One recap poster as a 1200×630 image, drawn on a canvas in the browser like the public page's
 * share card: nothing leaves the browser until the reader pastes it somewhere.
 */
export type RecapCard = {
  /** `Volume`, `Model of the week`, … */
  eyebrow: string;
  headline: string;
  sentence: string;
  /** `Sep 14 – Sep 20, 2026` */
  dates: string;
  /** Model names draw in the monospace face. */
  mono?: boolean;
};

const INK = "#0b0b0b";
const MUTED = "#6b6b6b";
const CANVAS = "#ffffff";
const EMERALD = "#087456";
const HAIRLINE = "#e5e5e5";
const SANS = 'ui-rounded, "SF Pro Rounded", ui-sans-serif, system-ui, -apple-system, sans-serif';
const MONO = 'ui-monospace, "SF Mono", Menlo, Consolas, monospace';

export function drawRecapCard(canvas: HTMLCanvasElement, card: RecapCard): void {
  canvas.width = SHARE_CARD_WIDTH;
  canvas.height = SHARE_CARD_HEIGHT;
  const context = canvas.getContext("2d");
  if (!context) return;
  context.fillStyle = CANVAS;
  context.fillRect(0, 0, SHARE_CARD_WIDTH, SHARE_CARD_HEIGHT);
  context.strokeStyle = HAIRLINE;
  context.lineWidth = 2;
  context.strokeRect(32, 32, SHARE_CARD_WIDTH - 64, SHARE_CARD_HEIGHT - 64);

  context.textBaseline = "alphabetic";
  context.fillStyle = EMERALD;
  context.font = `600 24px ${SANS}`;
  context.fillText(card.eyebrow.toUpperCase(), 88, 124);

  context.fillStyle = INK;
  let size = card.mono ? 88 : 112;
  const face = card.mono ? MONO : SANS;
  context.font = `500 ${size}px ${face}`;
  while (context.measureText(card.headline).width > SHARE_CARD_WIDTH - 176 && size > 40) {
    size -= 4;
    context.font = `500 ${size}px ${face}`;
  }
  context.fillText(card.headline, 88, 300);

  context.fillStyle = MUTED;
  context.font = `400 34px ${SANS}`;
  let line = "";
  let y = 380;
  for (const word of card.sentence.split(" ")) {
    const next = line ? `${line} ${word}` : word;
    if (context.measureText(next).width > SHARE_CARD_WIDTH - 176 && line) {
      context.fillText(line, 88, y);
      line = word;
      y += 46;
    } else {
      line = next;
    }
  }
  if (line) context.fillText(line, 88, y);

  context.font = `400 24px ${SANS}`;
  context.fillText(`Quota weekly recap · ${card.dates}`, 88, SHARE_CARD_HEIGHT - 76);
  context.textAlign = "right";
  context.fillText("quota.gotry.io", SHARE_CARD_WIDTH - 88, SHARE_CARD_HEIGHT - 76);
  context.textAlign = "left";
}

/**
 * Put the poster on the clipboard as a PNG. The blob is handed over as a promise so Safari keeps
 * the click's permission while the canvas encodes.
 */
export async function copyRecapCard(card: RecapCard): Promise<boolean> {
  if (typeof ClipboardItem === "undefined" || !navigator.clipboard?.write) return false;
  const canvas = document.createElement("canvas");
  drawRecapCard(canvas, card);
  const png = new Promise<Blob>((resolve, reject) => {
    canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error("encode"))), "image/png");
  });
  try {
    await navigator.clipboard.write([new ClipboardItem({ "image/png": png })]);
    return true;
  } catch {
    return false;
  }
}
