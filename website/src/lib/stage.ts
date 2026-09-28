import type { CSSProperties } from "react";

// The den window mock is laid out in the 1280×803 coordinate space of the
// real screenshots, then scaled with container units, so crops line up.
export const W = 1280;
export const H = 803;

export const box = (x: number, y: number, w?: number, h?: number): CSSProperties => ({
  left: `${(x / W) * 100}%`,
  top: `${(y / H) * 100}%`,
  ...(w === undefined ? {} : { width: `${(w / W) * 100}%` }),
  ...(h === undefined ? {} : { height: `${(h / H) * 100}%` }),
});

// Content card inside the window (from main-dark.png).
export const CARD = { x: 199, y: 9, w: 1072, h: 785 };

// Box relative to the content card.
export const inCard = (x: number, y: number, w: number, h: number): CSSProperties => ({
  left: `${(x / CARD.w) * 100}%`,
  top: `${(y / CARD.h) * 100}%`,
  width: `${(w / CARD.w) * 100}%`,
  height: `${(h / CARD.h) * 100}%`,
});

export const ROW = { first: 181, today: 388, pitch: 35.6, height: 32 };

export const rowY = (i: number, start: number) => start + i * ROW.pitch;
