export type IosAvailability = "coming-soon" | "testflight" | "app-store";

/** Owner switches this when TestFlight or the App Store is actually available. */
export const IOS_AVAILABILITY: IosAvailability = "coming-soon";

const IOS_AVAILABILITY_COPY: Record<IosAvailability, { label: string; summary: string }> = {
  "coming-soon": {
    label: "Coming soon",
    summary: "Quota for iPhone is coming soon.",
  },
  testflight: {
    label: "TestFlight",
    summary: "Quota for iPhone is on TestFlight.",
  },
  "app-store": {
    label: "App Store",
    summary: "Quota for iPhone is on the App Store.",
  },
};

export function iosAvailabilityCopy(status: IosAvailability): {
  label: string;
  summary: string;
} {
  return IOS_AVAILABILITY_COPY[status];
}
