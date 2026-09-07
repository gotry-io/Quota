<script lang="ts">
import type { UsageHourOfDay } from "@gotry-io/quota-protocol";
import { activityLevel, formatCount } from "$lib/format";

let {
  hoursOfDay,
  weekdayHours,
  id = "usage-rhythm",
}: {
  hoursOfDay: UsageHourOfDay[];
  weekdayHours: number[][];
  id?: string;
} = $props();

const weekdayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const hourLabels = [0, 6, 12, 18];
const maximumCell = $derived(Math.max(0, ...weekdayHours.flat()));
const maximumBar = $derived(Math.max(0, ...hoursOfDay.map((hour) => hour.total_tokens)));
const hasUsage = $derived(hoursOfDay.some((hour) => hour.total_tokens > 0));

function barPercent(tokens: number): number {
  return maximumBar > 0 ? (tokens / maximumBar) * 100 : 0;
}

function hourTitle(hour: number, tokens: number): string {
  return `${String(hour).padStart(2, "0")}:00 · ${formatCount(tokens)} tokens`;
}
</script>

{#if hasUsage}
  <div class="usage-rhythm" {id}>
    <div
      class="usage-rhythm-heat"
      role="img"
      aria-label="Usage by weekday and hour"
    >
      <div class="usage-rhythm-weekdays" aria-hidden="true">
        {#each weekdayLabels as label, weekday (label + weekday)}
          <span>{label}</span>
        {/each}
      </div>
      <div class="usage-rhythm-grid">
        {#each weekdayHours as row, weekday (weekday)}
          {#each row as tokens, hour (hour)}
            <i
              class="usage-rhythm-cell activity-level-{activityLevel(tokens, maximumCell)}"
              title="{weekdayLabels[weekday]} {hourTitle(hour, tokens)}"
            ></i>
          {/each}
        {/each}
      </div>
    </div>
    <div class="usage-rhythm-bars" role="img" aria-label="Usage by hour of the day">
      {#each hoursOfDay as hour (hour.hour)}
        <div class="usage-rhythm-column" title={hourTitle(hour.hour, hour.total_tokens)}>
          <span
            class="usage-rhythm-bar"
            style:height="{hour.total_tokens > 0 ? barPercent(hour.total_tokens) : 6}%"
            class:empty={hour.total_tokens === 0}
          ></span>
        </div>
      {/each}
    </div>
    <div class="usage-rhythm-hours" aria-hidden="true">
      {#each hourLabels as hour (hour)}
        <span style:grid-column={hour + 1}>{hour}</span>
      {/each}
    </div>
  </div>
{/if}
