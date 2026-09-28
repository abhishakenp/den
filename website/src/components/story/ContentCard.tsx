import type { CSSProperties } from "react";
import Image from "next/image";
import { CARD, box, inCard } from "@/lib/stage";
import { Deferred } from "@/components/story/Deferred";

// Stage width is ~62% of a 1320px layout on desktop, the full width on phones.
const FULL = "(min-width: 1024px) 700px, 90vw";

export const ContentCard = () => (
  <div className="st-card" style={box(CARD.x, CARD.y, CARD.w, CARD.h)}>
    <Deferred>
    <Image src="/story/page.png" alt="" width={1072} height={785} sizes={FULL} className="st-fill st-page" />

    <div className="st-split">
      <div className="st-pane st-split-l" style={inCard(0, 0, 530, 785)}>
        <Image src="/story/split-left.png" alt="" fill sizes="(min-width: 1024px) 350px, 45vw" className="object-cover object-top" />
      </div>
      <div className="st-pane st-split-r" style={inCard(538, 0, 534, 785)}>
        <Image src="/story/split-right.png" alt="" fill sizes="(min-width: 1024px) 350px, 45vw" className="object-cover object-top" />
      </div>
    </div>
    <div className="st-drop" style={inCard(357, 0, 715, 785)} />

    <div className="st-videobg" />
    <div className="st-dim" />

    <div className="st-cmd" style={inCard(108, 224, 667, 370)}>
      <Image src="/story/command.png" alt="" fill sizes="(min-width: 1024px) 440px, 60vw" />
      <div className="st-cmd-field">
        <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" className="st-cmd-icon">
          <circle cx="7" cy="7" r="4.5" />
          <path d="m10.5 10.5 3 3" strokeLinecap="round" />
        </svg>
        <span className="st-ch" style={{ "--n": 0 } as CSSProperties}>s</span>
        <span className="st-ch" style={{ "--n": 1 } as CSSProperties}>w</span>
        <span className="st-ch" style={{ "--n": 2 } as CSSProperties}>i</span>
      </div>
      <div className="st-cmd-cover" />
    </div>

    <div className="st-peek-chrome">
      <span className="st-pill" style={inCard(496, 13, 80, 22)}>swift.org</span>
      <span className="st-peek-btns" style={inCard(1004, 50, 36, 116)}>
        <i>×</i>
        <i>⤢</i>
        <i>◫</i>
      </span>
    </div>
    <div className="st-peek" style={inCard(56, 48, 930, 720)}>
      <Image src="/story/peek.png" alt="" fill sizes="(min-width: 1024px) 610px, 80vw" />
    </div>

    <div className="st-brief">
      <Image src="/story/briefing.png" alt="" fill sizes={FULL} className="object-cover object-top" />
    </div>
    </Deferred>
  </div>
);
