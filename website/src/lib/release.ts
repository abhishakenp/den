import { REPO, REPO_URL } from "@/lib/site";

export type Release = {
  tag: string;
  name: string;
  prerelease: boolean;
  publishedAt: string;
  pageUrl: string;
  dmgUrl: string;
  dmgSizeMB: number | null;
};

type GhAsset = { name: string; browser_download_url: string; size: number };
type GhRelease = {
  tag_name: string;
  name: string | null;
  prerelease: boolean;
  draft: boolean;
  published_at: string;
  html_url: string;
  assets: GhAsset[];
};

const FALLBACK: Release = {
  tag: "",
  name: "Latest release",
  prerelease: true,
  publishedAt: "",
  pageUrl: `${REPO_URL}/releases`,
  dmgUrl: `${REPO_URL}/releases`,
  dmgSizeMB: null,
};

const toRelease = (r: GhRelease): Release => {
  const dmg = r.assets.find((a) => a.name.endsWith(".dmg"));
  return {
    tag: r.tag_name,
    name: r.name ?? r.tag_name,
    prerelease: r.prerelease,
    publishedAt: r.published_at,
    pageUrl: r.html_url,
    dmgUrl: dmg?.browser_download_url ?? r.html_url,
    dmgSizeMB: dmg ? Math.round((dmg.size / 1_000_000) * 10) / 10 : null,
  };
};

// den ships pre-releases only for now, and GitHub's /releases/latest skips those,
// so take the newest non-draft release that has a DMG.
export const getLatestRelease = async (): Promise<Release> => {
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=10`, {
      headers: {
        Accept: "application/vnd.github+json",
        ...(process.env.GITHUB_TOKEN ? { Authorization: `Bearer ${process.env.GITHUB_TOKEN}` } : {}),
      },
      next: { revalidate: 3600 },
    });
    if (!res.ok) return FALLBACK;
    const releases = (await res.json()) as GhRelease[];
    const latest = releases.find((r) => !r.draft && r.assets.some((a) => a.name.endsWith(".dmg")));
    return latest ? toRelease(latest) : FALLBACK;
  } catch {
    return FALLBACK;
  }
};

export const formatDate = (iso: string) =>
  iso
    ? new Date(iso).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" })
    : "";
