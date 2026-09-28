import Image from "next/image";

type Props = {
  src: string;
  alt: string;
  width?: number;
  height?: number;
  priority?: boolean;
  sizes?: string;
  className?: string;
};

export const Shot = ({ src, alt, width = 1280, height = 803, priority, sizes, className = "" }: Props) => (
  <div className={`shot-frame overflow-clip rounded-[14px] bg-panel ${className}`}>
    <Image
      src={src}
      alt={alt}
      width={width}
      height={height}
      priority={priority}
      sizes={sizes ?? "(min-width: 1200px) 1100px, 100vw"}
      className="block h-auto w-full"
    />
  </div>
);
