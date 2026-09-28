"use client";

import { useEffect } from "react";

const supportsScrollTimelines = () =>
  typeof CSS !== "undefined" && CSS.supports("animation-timeline: view()");

// Where CSS scroll-driven animations can't run (no support, or reduced motion),
// the story switches to stepped states: an IntersectionObserver marks each beat
// as it reaches the middle of the viewport. No per-frame work either way.
const useStorySteps = () => {
  useEffect(() => {
    const story = document.querySelector<HTMLElement>("[data-story]");
    if (!story) return;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (supportsScrollTimelines() && !reduced) return;

    story.dataset.mode = "steps";
    const beats = [...story.querySelectorAll<HTMLElement>("[data-beat]")];
    const setStep = (n: number) => beats.forEach((_, i) => story.classList.toggle(`s${i + 1}`, i < n));

    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (!e.isIntersecting) continue;
          setStep(Number((e.target as HTMLElement).dataset.beat));
        }
      },
      { rootMargin: "-45% 0px -45% 0px" },
    );
    beats.forEach((b) => io.observe(b));
    return () => io.disconnect();
  }, []);
};

// Cursor-reactive glow on [data-glow] cards: one delegated listener, and the
// glow itself moves with transform (fx.css).
const useGlow = () => {
  useEffect(() => {
    if (!window.matchMedia("(hover: hover) and (pointer: fine)").matches) return;
    let frame = 0;
    const onMove = (e: PointerEvent) => {
      const el = (e.target as Element | null)?.closest<HTMLElement>("[data-glow]");
      if (!el || frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        const r = el.getBoundingClientRect();
        el.style.setProperty("--gx", `${e.clientX - r.left}px`);
        el.style.setProperty("--gy", `${e.clientY - r.top}px`);
      });
    };
    document.addEventListener("pointermove", onMove, { passive: true });
    return () => document.removeEventListener("pointermove", onMove);
  }, []);
};

export const useScrollFx = () => {
  useStorySteps();
  useGlow();
};
