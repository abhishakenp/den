import Image from "next/image";
import { REPO_URL, doc } from "@/lib/site";
import { CopyCommand } from "@/components/ui/CopyCommand";
import { GitHubIcon } from "@/components/ui/Icons";

export const OpenSource = () => (
  <section id="source" className="px-4 pb-24 sm:px-6 sm:pb-32">
    <div className="relative mx-auto max-w-6xl overflow-clip rounded-3xl border border-line bg-ground-2 px-6 py-14 sm:px-14 sm:py-20">
      <div aria-hidden className="hearth pointer-events-none absolute inset-x-0 bottom-[-240px] mx-auto h-[520px] w-[900px]" />
      <div className="relative grid items-center gap-12 lg:grid-cols-[1fr_auto]">
        <div className="max-w-xl">
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-ember">Open source · MIT</p>
          <h2 className="text-gradient mt-4 text-3xl font-semibold tracking-tight sm:text-5xl sm:leading-[1.05]">
            Built in the open. Come build it with us.
          </h2>
          <p className="mt-5 text-lg leading-relaxed text-ink-soft">
            den is early. Design feedback is the most useful contribution right now: open an issue to discuss an idea or
            challenge a decision. The roadmap says what&rsquo;s done and what&rsquo;s next.
          </p>
          <div className="mt-8 space-y-3">
            <CopyCommand command="git clone https://github.com/abhishakenp/den.git && cd den && scripts/install.sh" label="build command" />
            <p className="text-sm text-ink-mute">Builds, runs the tests, installs to /Applications. Needs Xcode 26 and an Embedded Swift toolchain.</p>
          </div>
          <div className="mt-8 flex flex-wrap gap-3">
            <a
              href={REPO_URL}
              className="inline-flex h-11 items-center gap-2 rounded-xl bg-ink px-5 font-medium text-ground transition hover:bg-ember-hi"
            >
              <GitHubIcon /> Star on GitHub
            </a>
            <a
              href={`${REPO_URL}/issues`}
              className="inline-flex h-11 items-center rounded-xl border border-line-2 px-5 font-medium text-ink transition hover:border-ink-mute"
            >
              Open an issue
            </a>
            <a
              href={doc("ROADMAP.md")}
              className="inline-flex h-11 items-center rounded-xl border border-line-2 px-5 font-medium text-ink transition hover:border-ink-mute"
            >
              Roadmap
            </a>
          </div>
        </div>
        <div className="doorway mx-auto">
          <Image
            src="/den-icon.png"
            alt="den app icon"
            width={220}
            height={220}
            className="size-32 rounded-[30px] shadow-[0_0_0_1px_rgb(255_255_255/0.08),0_30px_80px_-10px_rgb(217_105_47/0.45)] lg:size-[220px] lg:rounded-[52px]"
          />
        </div>
      </div>
    </div>
  </section>
);
