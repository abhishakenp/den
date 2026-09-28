import { FEATURES } from "@/lib/content";

// The story above covers the rest; these are the everyday extras.
const MORE = FEATURES.filter((f) => ["extensions", "privacy", "pagetools", "sidebar"].includes(f.id));
import { SectionHeader } from "@/components/ui/SectionHeader";
import { TourTabs } from "@/components/TourTabs";

export const Tour = () => (
  <section id="more" className="relative px-4 py-24 sm:px-6 sm:py-32">
    <div aria-hidden className="hairline absolute inset-x-0 top-0" />
    <div className="mx-auto max-w-6xl">
      <SectionHeader
        eyebrow="And more"
        title="The everyday things, done well."
        lead="Everything here works in today's build."
      />
      <TourTabs features={MORE} />
    </div>
  </section>
);
