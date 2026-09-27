import { formatDate, type Release } from "@/lib/release";
import { doc } from "@/lib/site";
import { CopyCommand } from "@/components/ui/CopyCommand";
import { DownloadIcon } from "@/components/ui/Icons";

type Props = { release: Release };

const STEPS = [
  "Open the DMG and drag den to Applications.",
  "The first time, right-click den ▸ Open. It's signed ad hoc and not notarized yet.",
  "⌘T opens the command bar. That's most of den.",
];

export const Download = ({ release }: Props) => (
  <section id="download" className="px-4 py-24 sm:px-6 sm:py-32">
    <div className="mx-auto grid max-w-6xl gap-10 lg:grid-cols-[1.1fr_1fr] lg:gap-16">
      <div>
        <p className="font-mono text-xs uppercase tracking-[0.2em] text-ember">Download</p>
        <h2 className="text-gradient mt-4 text-3xl font-semibold tracking-tight sm:text-5xl sm:leading-[1.05]">
          Try the alpha.
        </h2>
        <p className="mt-5 max-w-xl text-lg leading-relaxed text-ink-soft">
          It browses the web with the sidebar, spaces, split view and command bar. There are no downloads, import or
          sync yet. Expect rough edges, and please report them.
        </p>

        <div className="mt-8 rounded-2xl border border-line bg-panel/60 p-5 sm:p-6">
          <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
            <span className="font-mono text-sm text-ink">{release.tag || "latest pre-release"}</span>
            {release.publishedAt ? (
              <span className="font-mono text-xs text-ink-mute">{formatDate(release.publishedAt)}</span>
            ) : null}
            <span className="rounded-full border border-ember/30 bg-ember/10 px-2 py-0.5 font-mono text-[11px] text-ember-hi">
              pre-release
            </span>
          </div>
          <div className="mt-5 flex flex-col gap-3 sm:flex-row">
            <a
              href={release.dmgUrl}
              className="inline-flex h-11 items-center justify-center gap-2 rounded-xl bg-gradient-to-b from-ember-hi to-ember px-5 font-medium text-ground transition hover:brightness-110"
            >
              <DownloadIcon />
              Download DMG
              {release.dmgSizeMB ? <span className="font-mono text-xs opacity-70">{release.dmgSizeMB} MB</span> : null}
            </a>
            <a
              href={release.pageUrl}
              className="inline-flex h-11 items-center justify-center rounded-xl border border-line-2 px-5 text-sm font-medium text-ink-soft transition hover:text-ink"
            >
              Release notes
            </a>
          </div>
          <p className="mt-4 text-sm text-ink-mute">Requires macOS 26 Tahoe or later.</p>
        </div>
      </div>

      <div className="flex flex-col gap-6 lg:pt-14">
        <ol className="space-y-4">
          {STEPS.map((s, i) => (
            <li key={s} className="flex gap-4">
              <span className="grid size-7 shrink-0 place-items-center rounded-full border border-line-2 font-mono text-xs text-ember">
                {i + 1}
              </span>
              <span className="pt-0.5 text-ink-soft">{s}</span>
            </li>
          ))}
        </ol>
        <div className="space-y-2">
          <p className="text-sm text-ink-mute">Or clear the quarantine flag from a terminal:</p>
          <CopyCommand command="xattr -dr com.apple.quarantine /Applications/den.app" />
        </div>
        <div className="space-y-2">
          <p className="text-sm text-ink-mute">
            Get the next alpha as an update: add this to <code className="font-mono text-ink-soft">~/.den/config.toml</code>
          </p>
          <pre className="overflow-x-auto rounded-xl border border-line bg-ground-2/80 px-4 py-3 font-mono text-[13px] leading-6 text-ink">
            <span className="text-ember/80">[updates]</span>
            {"\n"}channel = <span className="text-good">&quot;prerelease&quot;</span>
          </pre>
          <p className="text-sm text-ink-mute">
            Prefer to build it? <a className="text-ink-soft underline decoration-line-2 underline-offset-4 hover:text-ink" href={doc("docs/guide/getting-started.md#build-from-source")}>Build from source</a> with Xcode 26 and an Embedded Swift toolchain.
          </p>
        </div>
      </div>
    </div>
  </section>
);
