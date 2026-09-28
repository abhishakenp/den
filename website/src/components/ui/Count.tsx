import type { CSSProperties } from "react";
import { parseCount } from "@/lib/count";

type Props = { label: string };

// Ticks up from 0 as it scrolls into view, in CSS (fx.css: @property + counter()).
// The real text stays in the DOM for screen readers and non-supporting browsers.
export const Count = ({ label }: Props) => {
  const c = parseCount(label);
  if (!c) return <>{label}</>;
  return (
    <>
      {c.prefix}
      <span className="count-static">{c.number}</span>
      <span
        aria-hidden
        className="count-anim"
        data-thousands={c.thousands === undefined ? undefined : ""}
        style={{ "--to": c.units, "--tok": c.thousands ?? 0, "--w": c.number.length } as CSSProperties}
      />
      {c.suffix}
    </>
  );
};
