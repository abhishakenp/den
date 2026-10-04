import { Sidebar } from "@/components/story/Sidebar";
import { ContentCard } from "@/components/story/ContentCard";
import { Overlays } from "@/components/story/Overlays";

export const StoryStage = () => (
  <div className="st-pin">
    <div className="st-persp">
      <div
        role="img"
        aria-label="A den window: tabs appear in the sidebar, the space swipes to Work, the command bar opens, a link opens in a Peek, a tab is dragged into split view, a pull request preview appears on hover, a video floats off into picture in picture, and the briefing opens."
        className="st-window"
      >
        <div className="st-ui">
          <div className="st-theme st-theme-a" />
          <div className="st-theme st-theme-b" />
          <Sidebar />
          <ContentCard />
          <Overlays />
        </div>
      </div>
    </div>
  </div>
);
