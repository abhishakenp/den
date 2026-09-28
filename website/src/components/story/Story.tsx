import { BEATS } from "@/lib/story";
import { StoryStage } from "@/components/story/StoryStage";
import { StoryBeat } from "@/components/story/StoryBeat";

// Pinned scrollytelling: the den window stays put while the beats scroll by.
// Every scene is a CSS scroll-driven animation keyed to a beat's view timeline
// (app/story.css); ScrollFx switches to stepped states where that's unsupported
// or motion is reduced.
export const Story = () => (
  <section id="tour" aria-label="A tour of den" className="story relative px-4 sm:px-6 lg:-mt-[20svh]" data-story>
    <h2 className="sr-only">A tour of den</h2>
    <div className="mx-auto grid max-w-[1320px] lg:grid-cols-[minmax(0,4fr)_minmax(0,9fr)] lg:gap-12">
      <div className="st-stage-col lg:col-start-2 lg:row-start-1">
        <StoryStage />
      </div>
      <div className="st-beats lg:col-start-1 lg:row-start-1">
        {BEATS.map((b, i) => (
          <StoryBeat key={b.id} beat={b} index={i} total={BEATS.length} />
        ))}
      </div>
    </div>
  </section>
);
