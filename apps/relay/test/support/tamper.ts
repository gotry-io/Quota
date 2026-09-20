/// Changing one character of a signed value, with the change proven rather than assumed.
///
/// A mutation that replaces the last character with a fixed one is a no-op whenever the value
/// already ends in it, and a test that then sees the request accepted is reading the right answer
/// for a valid input as a security failure. This returns a value that differs, and says so if it
/// ever cannot.
export function tamperedLastCharacter(value: string): string {
  if (value.length === 0) throw new Error("nothing to tamper with: the value is empty");
  const last = value.at(-1) ?? "";
  const replacement = last === "0" ? "1" : "0";
  const tampered = `${value.slice(0, -1)}${replacement}`;
  if (tampered === value) {
    throw new Error(`tampering changed nothing: ${value} is unchanged`);
  }
  return tampered;
}
