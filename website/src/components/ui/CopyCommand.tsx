"use client";

import { useCopy } from "@/hooks/useCopy";
import { CheckIcon, CopyIcon } from "@/components/ui/Icons";

type Props = { command: string; prompt?: string; label?: string };

export const CopyCommand = ({ command, prompt = "$", label }: Props) => {
  const { copied, copy } = useCopy(command);
  return (
    <div className="group relative flex items-start gap-3 rounded-xl border border-line bg-ground-2/80 py-3 pl-4 pr-12 font-mono text-[13px] leading-6 text-ink">
      <span aria-hidden className="select-none text-ember/80">
        {prompt}
      </span>
      <code tabIndex={0} className="min-w-0 flex-1 overflow-x-auto whitespace-pre [scrollbar-width:thin]">{command}</code>
      <button
        type="button"
        onClick={copy}
        aria-label={copied ? "Copied" : `Copy ${label ?? "command"}`}
        className="absolute right-2 top-2 grid size-8 place-items-center rounded-lg text-ink-mute transition hover:bg-panel-2 hover:text-ink"
      >
        {copied ? <CheckIcon className="text-good" /> : <CopyIcon />}
      </button>
      <span aria-live="polite" className="sr-only">
        {copied ? "Copied to clipboard" : ""}
      </span>
    </div>
  );
};
