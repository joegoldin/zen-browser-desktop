/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

add_task(async function test_SimpleTabOpen() {
  const initialTabs = new Set(gBrowser.tabs);
  await withNewTabAndWindow(async (newTab, win) => {
    let tabId = newTab.id;
    let otherTab = gZenWindowSync.getItemFromWindow(win, tabId);
    Assert.ok(otherTab, "The opened tab should be found in the synced window");
    Assert.ok(newTab._zenContentsVisible, "The opened tab should be visible");
    Assert.equal(
      otherTab.id,
      tabId,
      "The opened tab ID should match the synced tab ID"
    );
  });
  // Window sync mirrors the synced window's blank tab into this one.
  const closing = [];
  for (const tab of [...gBrowser.tabs]) {
    if (!initialTabs.has(tab) && !tab.closing) {
      closing.push(BrowserTestUtils.waitForTabClosing(tab));
      BrowserTestUtils.removeTab(tab);
    }
  }
  await Promise.all(closing);
});

add_task(async function test_TabOpenInContainer() {
  await SpecialPowers.pushPrefEnv({
    set: [["privacy.userContext.enabled", true]],
  });
  const initialTabs = new Set(gBrowser.tabs);
  let newTab = null;
  await withNewSyncedWindow(async win => {
    await runSyncAction(
      () => {
        newTab = gBrowser.addTrustedTab("https://example.com/", {
          inBackground: true,
          userContextId: 1,
        });
      },
      async () => {
        Assert.equal(
          newTab.userContextId,
          1,
          "The opened tab should keep its container"
        );
        const otherTab = gZenWindowSync.getItemFromWindow(win, newTab.id);
        Assert.ok(
          otherTab,
          "The opened tab should be found in the synced window"
        );
        Assert.equal(
          otherTab.userContextId,
          newTab.userContextId,
          "The synced tab should inherit the original tab's container"
        );
      },
      "TabOpen",
      aEvent => aEvent.target === newTab
    );
  });
  // Window sync mirrors the synced window's blank tab into this one, so the
  // opened tab is not the only one left behind.
  const closing = [];
  for (const tab of [...gBrowser.tabs]) {
    if (!initialTabs.has(tab) && !tab.closing) {
      closing.push(BrowserTestUtils.waitForTabClosing(tab));
      BrowserTestUtils.removeTab(tab);
    }
  }
  await Promise.all(closing);
});
