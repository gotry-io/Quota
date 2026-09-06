import { inferenceProviderDisplayName, type PublicUsageResponse } from "@gotry-io/quota-protocol";
import { formatCost, formatCount } from "./format.ts";
import { sharePercent } from "./public-profile.ts";
import { publicProfileUrl } from "./routes.ts";

/** The one card size every social preview crops from. */
export const SHARE_CARD_WIDTH = 1200;
export const SHARE_CARD_HEIGHT = 630;

/** How many provider bars fit above the footer without crowding it. */
const SHARE_CARD_BARS = 3;

/** Classic is the only style. A second one would be a second thing to keep true. */
const INK = "#0b0b0b";
const MUTED = "#6b6b6b";
const HAIRLINE = "#e5e5e5";
const CANVAS = "#ffffff";
const EMERALD = "#087456";
const BAR_TRACK = "#eef2f0";

const SANS = 'Inter, "Helvetica Neue", Arial, sans-serif';

interface ShareCardStat {
  label: string;
  value: string;
}

export interface ShareCardModel {
  handle: string;
  url: string;
  period: string;
  stats: ShareCardStat[];
  bars: Array<{ label: string; permille: number; share: string }>;
  footer: string;
}

/**
 * What the card says, decided before anything is drawn.
 *
 * Keeping this apart from the drawing is what lets a test read the card: the numbers, the
 * wording, and the bar lengths are answerable without a canvas, and the drawing below adds
 * nothing but position.
 */
export function shareCardModel(profile: PublicUsageResponse): ShareCardModel {
  const period = profile.last_30_days;
  const stats: ShareCardStat[] = [
    { label: "Tokens", value: formatCount(period.totals.total_tokens) },
    { label: "Messages", value: formatCount(period.totals.messages) },
  ];
  if (period.cost) {
    stats.push({ label: "API-equivalent", value: formatCost(period.cost) });
  }
  return {
    handle: profile.handle,
    url: publicProfileUrl(profile.handle),
    period: "Last 30 days",
    stats,
    bars: period.providers.slice(0, SHARE_CARD_BARS).map((share) => ({
      label: inferenceProviderDisplayName(share.provider),
      permille: share.share_permille,
      share: sharePercent(share.share_permille),
    })),
    footer: "Quota · quota.gotry.io",
  };
}

/**
 * Draw the card at its full 1200x630, whatever size the element is shown at.
 *
 * The canvas is always these pixels and CSS scales the preview down, so the picture the dialog
 * shows and the file it saves are the same drawing rather than two.
 */
export function drawShareCard(canvas: HTMLCanvasElement, model: ShareCardModel): void {
  canvas.width = SHARE_CARD_WIDTH;
  canvas.height = SHARE_CARD_HEIGHT;
  const context = canvas.getContext("2d");
  if (!context) return;
  context.fillStyle = CANVAS;
  context.fillRect(0, 0, SHARE_CARD_WIDTH, SHARE_CARD_HEIGHT);

  context.strokeStyle = HAIRLINE;
  context.lineWidth = 2;
  context.strokeRect(32, 32, SHARE_CARD_WIDTH - 64, SHARE_CARD_HEIGHT - 64);

  context.fillStyle = EMERALD;
  context.font = `600 26px ${SANS}`;
  context.textBaseline = "alphabetic";
  context.fillText("QUOTA", 88, 118);

  context.fillStyle = INK;
  context.font = `700 72px ${SANS}`;
  context.fillText(`@${model.handle}`, 88, 206);

  context.fillStyle = MUTED;
  context.font = `400 28px ${SANS}`;
  context.fillText(model.period, 88, 248);

  let x = 88;
  for (const stat of model.stats) {
    context.fillStyle = INK;
    context.font = `700 64px ${SANS}`;
    context.fillText(stat.value, x, 348);
    context.fillStyle = MUTED;
    context.font = `400 24px ${SANS}`;
    context.fillText(stat.label, x, 384);
    x += 320;
  }

  let y = 430;
  for (const bar of model.bars) {
    context.fillStyle = MUTED;
    context.font = `400 22px ${SANS}`;
    context.fillText(bar.label, 88, y + 16);
    context.fillStyle = BAR_TRACK;
    context.fillRect(300, y, 560, 20);
    context.fillStyle = EMERALD;
    context.fillRect(300, y, Math.max(4, (560 * bar.permille) / 1_000), 20);
    context.fillStyle = INK;
    context.font = `500 22px ${SANS}`;
    context.fillText(bar.share, 880, y + 16);
    y += 40;
  }

  context.fillStyle = MUTED;
  context.font = `400 24px ${SANS}`;
  context.fillText(model.url, 88, SHARE_CARD_HEIGHT - 60);
  context.textAlign = "right";
  context.fillText(model.footer, SHARE_CARD_WIDTH - 88, SHARE_CARD_HEIGHT - 60);
  context.textAlign = "left";
}

/** The filename a saved card takes, so two saved cards do not collide in a downloads folder. */
export function shareCardFilename(handle: string): string {
  return `quota-${handle}.png`;
}
