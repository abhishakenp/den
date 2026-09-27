import { DOCS } from "@/lib/content";
import { TREE } from "@/lib/site";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { ArrowIcon } from "@/components/ui/Icons";

export const Docs = () => (
  <section id="docs" className="relative px-4 py-24 sm:px-6 sm:py-32">
    <div aria-hidden className="hairline absolute inset-x-0 top-0" />
    <div className="mx-auto max-w-6xl">
      <div className="flex flex-col gap-6 sm:flex-row sm:items-end sm:justify-between">
        <SectionHeader
          eyebrow="Docs"
          title="A guide that's true of main."
          lead="One page per area. If a page says something den doesn't do, that's a bug."
        />
        <a
          href={`${TREE}/docs/guide`}
          className="inline-flex shrink-0 items-center gap-1.5 text-sm font-medium text-ink transition hover:text-ember-hi"
        >
          Open the user guide <ArrowIcon className="size-3.5" />
        </a>
      </div>

      <ul className="mt-12 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {DOCS.map((d) => (
          <li key={d.title}>
            <a
              href={d.href}
              className="group flex h-full flex-col rounded-2xl border border-line bg-ground-2 p-5 transition hover:border-ember/40 hover:bg-panel"
            >
              <span className="flex items-center justify-between font-medium">
                {d.title}
                <ArrowIcon className="size-3.5 -translate-x-1 text-ink-mute opacity-0 transition group-hover:translate-x-0 group-hover:text-ember group-hover:opacity-100" />
              </span>
              <span className="mt-2 text-sm leading-relaxed text-ink-soft">{d.body}</span>
            </a>
          </li>
        ))}
      </ul>
    </div>
  </section>
);
