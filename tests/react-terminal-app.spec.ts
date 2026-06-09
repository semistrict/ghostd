import { expect, test } from "@playwright/test";

const transports = [
  { name: "websocket", query: "" },
  { name: "event-stream", query: "?transport=event-stream" },
] as const;

for (const transport of transports) {
test(`${transport.name} React terminal app renders the real ghostd terminal chrome`, async ({
  page,
}) => {
  await page.goto(`/${transport.query}`);

  await expect(page.locator(".ghostd-react-shell")).toBeVisible();
  await expect(page.locator("#terminal .term-row").first()).toContainText("%");
  await expect(page.locator("#status")).toHaveText("writer");
  await expect(page.locator(".ghostd-react-connection-value")).toHaveAttribute(
    "data-state",
    "open",
  );
  await expect(page.locator('[data-terminal-tab="0"]')).toHaveAttribute(
    "aria-selected",
    "true",
  );
  await expect(page.locator("#new-terminal")).toBeVisible();
  await expect(page.locator("#claim-writer")).toBeHidden();
});
}
