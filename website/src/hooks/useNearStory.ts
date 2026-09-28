"use client";

import { useEffect, useState } from "react";

const afterLoad = (fn: () => void) => {
  const idle = () =>
    "requestIdleCallback" in window ? requestIdleCallback(fn, { timeout: 1500 }) : setTimeout(fn, 200);
  if (document.readyState === "complete") idle();
  else window.addEventListener("load", idle, { once: true });
};

// True once the page has loaded and the story is within a viewport of the
// screen. The stage's screenshots wait for it, so they never compete with the
// hero on first load.
export const useNearStory = () => {
  const [near, setNear] = useState(false);
  useEffect(() => {
    let io: IntersectionObserver | undefined;
    afterLoad(() => {
      const story = document.querySelector("[data-story]");
      if (!story) return setNear(true);
      io = new IntersectionObserver(
        (entries) => {
          if (!entries.some((e) => e.isIntersecting)) return;
          setNear(true);
          io?.disconnect();
        },
        { rootMargin: "100% 0px" },
      );
      io.observe(story);
    });
    return () => io?.disconnect();
  }, []);
  return near;
};
