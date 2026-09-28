"use client";

import type { ReactNode } from "react";
import { useNearStory } from "@/hooks/useNearStory";

export const Deferred = ({ children }: { children: ReactNode }) => {
  const near = useNearStory();
  return near ? <>{children}</> : null;
};
