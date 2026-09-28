import { getLatestRelease } from "@/lib/release";
import { Nav } from "@/components/Nav";
import { Hero } from "@/components/Hero";
import { Download } from "@/components/Download";
import { Principles } from "@/components/Principles";
import { Numbers } from "@/components/Numbers";
import { Tour } from "@/components/Tour";
import { Story } from "@/components/story/Story";
import { Proof } from "@/components/Proof";
import { Agents } from "@/components/Agents";
import { Docs } from "@/components/Docs";
import { OpenSource } from "@/components/OpenSource";
import { Footer } from "@/components/Footer";

export const revalidate = 3600;

const Home = async () => {
  const release = await getLatestRelease();
  return (
    <>
      <Nav />
      <main>
        <Hero release={release} />
        <Story />
        <Proof />
        <Download release={release} />
        <Principles />
        <Numbers />
        <Tour />
        <Agents />
        <Docs />
        <OpenSource />
      </main>
      <Footer />
    </>
  );
};

export default Home;
