import type { CSSProperties } from "react";

type Props = { keys: string[]; className?: string };

// Keys press in turn as they cross the middle of the viewport (see fx.css).
export const Keycaps = ({ keys, className = "" }: Props) => (
  <span className={`inline-flex items-center gap-1.5 ${className}`}>
    {keys.map((k, i) => (
      <kbd key={k + i} className="keycap" style={{ "--k": i } as CSSProperties}>
        {k}
      </kbd>
    ))}
  </span>
);
