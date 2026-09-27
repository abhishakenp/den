"use client";

import { useCallback, useRef, useState, type KeyboardEvent } from "react";

// Roving-tabindex tabs: arrow keys move between tabs, Home/End jump to the ends.
export const useTabs = (ids: readonly string[]) => {
  const [active, setActive] = useState(ids[0]);
  const refs = useRef<Record<string, HTMLButtonElement | null>>({});

  const focus = useCallback(
    (id: string) => {
      setActive(id);
      refs.current[id]?.focus();
    },
    [],
  );

  const onKeyDown = useCallback(
    (e: KeyboardEvent<HTMLElement>) => {
      const i = ids.indexOf(active);
      const next: Record<string, number> = {
        ArrowRight: (i + 1) % ids.length,
        ArrowDown: (i + 1) % ids.length,
        ArrowLeft: (i - 1 + ids.length) % ids.length,
        ArrowUp: (i - 1 + ids.length) % ids.length,
        Home: 0,
        End: ids.length - 1,
      };
      if (!(e.key in next)) return;
      e.preventDefault();
      focus(ids[next[e.key]]);
    },
    [active, ids, focus],
  );

  const register = useCallback(
    (id: string) => (el: HTMLButtonElement | null) => {
      refs.current[id] = el;
    },
    [],
  );

  return { active, setActive, onKeyDown, register };
};
