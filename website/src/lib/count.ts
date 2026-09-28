export type ParsedCount = {
  prefix: string;
  number: string; // the integer part as displayed, e.g. "2,147"
  units: number; // the counter's value (below 1,000 when thousands is set)
  thousands?: number;
  suffix: string; // decimals and unit, e.g. ".8 MB"
};

// "79.8 MB" → 79 + ".8 MB"; "2,147 ms" → 2 thousands, 147 units + " ms".
export const parseCount = (label: string): ParsedCount | null => {
  const m = label.match(/^(\D*?)(\d{1,3}(?:,\d{3})?|\d+)(.*)$/);
  if (!m) return null;
  const [, prefix, number, suffix] = m;
  const value = Number(number.replace(/,/g, ""));
  if (!Number.isFinite(value) || value > 999_999) return null;
  return value >= 1000
    ? { prefix, number, units: value % 1000, thousands: Math.floor(value / 1000), suffix }
    : { prefix, number, units: value, suffix };
};
