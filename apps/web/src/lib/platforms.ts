export type IosAvailability = "coming-soon" | "testflight" | "app-store";

export type IosAvailabilityCopy = {
  label: string;
  summary: string;
  url?: string;
  actionLabel?: string;
};

/** Owner switches this when TestFlight or the App Store is actually available. */
export const IOS_AVAILABILITY: IosAvailability = "coming-soon";

const IOS_AVAILABILITY_COPY: Record<IosAvailability, IosAvailabilityCopy> = {
  "coming-soon": {
    label: "Coming soon",
    summary: "iPhone app coming soon.",
  },
  testflight: {
    label: "TestFlight",
    summary: "Quota for iPhone is on TestFlight.",
    actionLabel: "Join TestFlight",
  },
  "app-store": {
    label: "App Store",
    summary: "Quota for iPhone is on the App Store.",
    actionLabel: "View in App Store",
  },
};

export function iosAvailabilityCopy(status: IosAvailability): IosAvailabilityCopy {
  return IOS_AVAILABILITY_COPY[status];
}
