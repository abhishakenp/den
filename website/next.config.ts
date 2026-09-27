import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  images: {
    formats: ["image/avif", "image/webp"],
    deviceSizes: [640, 828, 1080, 1280, 1920, 2560],
    minimumCacheTTL: 31536000,
  },
  poweredByHeader: false,
};

export default nextConfig;
