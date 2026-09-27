import { FEATURES } from "@/lib/content";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { TourTabs } from "@/components/TourTabs";

export const Tour = () => (
  <section id="tour" className="relative px-4 py-24 sm:px-6 sm:py-32">
    <div aria-hidden className="hairline absolute inset-x-0 top-0" />
    <div className="mx-auto max-w-6xl">
      <SectionHeader
        eyebrow="Tour"
        title="Everything you reach for, one plugin each."
        lead="What works on main today. Every item is covered by swift test or a scenario run of the real app."
      />
      <TourTabs features={FEATURES} />
    </div>
  </section>
);
