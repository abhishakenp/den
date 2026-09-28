import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono, Instrument_Serif } from "next/font/google";
import type { ReactNode } from "react";
import "@/app/globals.css";
import { ScrollFx } from "@/components/ScrollFx";

const geist = Geist({ subsets: ["latin"], variable: "--font-geist", display: "swap" });
const geistMono = Geist_Mono({ subsets: ["latin"], variable: "--font-geist-mono", display: "swap" });
const instrument = Instrument_Serif({
  subsets: ["latin"],
  weight: "400",
  style: "italic",
  variable: "--font-instrument",
  display: "swap",
});

const TITLE = "den: a fast, open-source macOS browser made of plugins";
const DESCRIPTION =
  "An Arc-style browser for macOS 26, built on WebKit from plugins you can swap live. 20 MB idle. MIT licensed.";

export const metadata: Metadata = {
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL ?? "https://den-browser.vercel.app"),
  title: TITLE,
  description: DESCRIPTION,
  openGraph: {
    title: TITLE,
    description: DESCRIPTION,
    type: "website",
    images: [{ url: "/og.png", width: 1200, height: 630, alt: "den's main window in dark mode" }],
  },
  twitter: { card: "summary_large_image", title: TITLE, description: DESCRIPTION, images: ["/og.png"] },
};

export const viewport: Viewport = { themeColor: "#0f0a0f", colorScheme: "dark" };

const RootLayout = ({ children }: { children: ReactNode }) => (
  <html lang="en" className={`${geist.variable} ${geistMono.variable} ${instrument.variable}`}>
    <body className="grain">
      <div aria-hidden className="aurora">
        <i />
        <i />
      </div>
      {children}
      <ScrollFx />
    </body>
  </html>
);

export default RootLayout;
