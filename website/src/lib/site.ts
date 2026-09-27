export const REPO = "abhishakenp/den";
export const REPO_URL = `https://github.com/${REPO}`;
export const BLOB = `${REPO_URL}/blob/main`;
export const TREE = `${REPO_URL}/tree/main`;
export const RAW = `https://raw.githubusercontent.com/${REPO}/main`;

export const doc = (path: string) => `${BLOB}/${path}`;

export const NAV = [
  { href: "#why", label: "Why" },
  { href: "#numbers", label: "Numbers" },
  { href: "#tour", label: "Tour" },
  { href: "#agents", label: "For agents" },
  { href: "#docs", label: "Docs" },
] as const;
