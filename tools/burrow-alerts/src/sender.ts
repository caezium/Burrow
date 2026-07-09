/**
 * Delivery via Photon spectrum-ts. Cloud mode (managed Photon line) when a
 * projectId + projectSecret are present; local mode (this Mac's chat.db)
 * otherwise. Space resolution + send are identical either way — a shared-mode
 * DM guid (`any;-;<addr>`) needs no server call.
 *
 * Cloud note: the target must be opted in (text the project's assigned line
 * once) or sends fail with "Target not allowed for this project".
 */

export type SendConfig = {
  recipient: string;
  projectId?: string;
  projectSecret?: string;
  forceLocal?: boolean;
};

const dmGuid = (addr: string) => `any;-;${addr}`;

export function toE164(phone: string): string {
  const raw = phone.trim();
  const digits = raw.replace(/\D/g, "");
  if (raw.startsWith("+")) return `+${digits}`;
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return raw; // email / already-odd handle: pass through
}

export function useCloud(cfg: SendConfig): boolean {
  return !cfg.forceLocal && Boolean(cfg.projectId && cfg.projectSecret);
}

/** Send one text. The inbound watcher is lazy, so this exits cleanly. */
export async function sendText(cfg: SendConfig, body: string): Promise<void> {
  const { Spectrum, text } = await import("spectrum-ts");
  const { imessage } = await import("spectrum-ts/providers/imessage");
  const to = toE164(cfg.recipient);
  const app = useCloud(cfg)
    ? await Spectrum({ projectId: cfg.projectId!, projectSecret: cfg.projectSecret!, providers: [imessage.config()] })
    : await Spectrum({ providers: [imessage.config({ local: true })] });
  try {
    const im = imessage(app);
    const space = await im.space.get(dmGuid(to));
    await space.send(text(body));
  } finally {
    await app.stop();
  }
}
