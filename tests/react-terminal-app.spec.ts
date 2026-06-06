import { expect, test } from "@playwright/test";

test("React terminal app renders the real ghostd terminal chrome", async ({
  page,
}) => {
  await page.goto("/");

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
