import type { ReactNode } from "react";

type Props = { eyebrow: string; title: ReactNode; lead?: ReactNode; center?: boolean };

export const SectionHeader = ({ eyebrow, title, lead, center }: Props) => (
  <header className={`reveal ${center ? "mx-auto max-w-2xl text-center" : "max-w-2xl"}`}>
    <p className="font-mono text-xs uppercase tracking-[0.2em] text-ember">{eyebrow}</p>
    <h2 className="text-gradient mt-4 text-balance text-3xl font-semibold tracking-tight sm:text-5xl sm:leading-[1.05]">
      {title}
    </h2>
    {lead ? <p className="mt-5 text-pretty text-lg leading-relaxed text-ink-soft">{lead}</p> : null}
  </header>
);
