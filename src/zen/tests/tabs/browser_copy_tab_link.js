/* Any copyright is dedicated to the Public Domain.
   https://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

const URL_ONE = "https://example.com/1";
const URL_TWO = "https://example.com/2";

function copyTabLinkAndWait(expected) {
  return new Promise((resolve, reject) => {
    waitForClipboard(
      expected,
      () => gZenCommonActions.copyTabLinkToClipboard(),
      resolve,
      reject
    );
  });
}

add_task(async function test_copy_single_tab_link() {
  const tab = await BrowserTestUtils.openNewForegroundTab(gBrowser, URL_ONE);

  gBrowser.clearMultiSelectedTabs();
  window.TabContextMenu.contextTab = tab;

  await copyTabLinkAndWait(URL_ONE);
  ok(true, "The link of a single tab is copied to the clipboard");

  window.TabContextMenu.contextTab = null;
  BrowserTestUtils.removeTab(tab);
});

add_task(async function test_copy_multiple_selected_tab_links() {
  const tabOne = await BrowserTestUtils.openNewForegroundTab(gBrowser, URL_ONE);
  const tabTwo = await BrowserTestUtils.openNewForegroundTab(gBrowser, URL_TWO);

  gBrowser.selectedTab = tabOne;
  gBrowser.addToMultiSelectedTabs(tabOne);
  gBrowser.addToMultiSelectedTabs(tabTwo);

  ok(tabOne.multiselected, "The first tab is part of the multi-selection");
  ok(tabTwo.multiselected, "The second tab is part of the multi-selection");

  window.TabContextMenu.contextTab = tabOne;

  const expected = gBrowser.selectedTabs
    .map(tab => tab.linkedBrowser.currentURI.displaySpec)
    .join("\n");
  ok(
    expected.includes(URL_ONE) && expected.includes(URL_TWO),
    "Both selected tab URLs are expected in the clipboard payload"
  );

  await copyTabLinkAndWait(expected);
  ok(true, "Every selected tab link is copied, one per line");

  window.TabContextMenu.contextTab = null;
  gBrowser.clearMultiSelectedTabs();
  BrowserTestUtils.removeTab(tabOne);
  BrowserTestUtils.removeTab(tabTwo);
});

add_task(async function test_copy_tab_link_menu_label_updates() {
  const tabOne = await BrowserTestUtils.openNewForegroundTab(gBrowser, URL_ONE);
  const tabTwo = await BrowserTestUtils.openNewForegroundTab(gBrowser, URL_TWO);

  const menuItem = document.getElementById("context_zen-copy-tab-link");
  ok(menuItem, "The copy tab link menu item is present");

  // A single context tab labels the item for one link.
  gBrowser.clearMultiSelectedTabs();
  gBrowser.selectedTab = tabOne;
  window.TabContextMenu.contextTab = tabOne;
  gZenPinnedTabManager.updatePinnedTabContextMenu(tabOne);
  Assert.deepEqual(
    JSON.parse(menuItem.getAttribute("data-l10n-args")),
    { tabCount: 1 },
    "The label reflects a single tab"
  );

  // A multi-selection labels the item with the number of selected tabs.
  gBrowser.addToMultiSelectedTabs(tabOne);
  gBrowser.addToMultiSelectedTabs(tabTwo);
  window.TabContextMenu.contextTab = tabOne;
  gZenPinnedTabManager.updatePinnedTabContextMenu(tabOne);
  Assert.deepEqual(
    JSON.parse(menuItem.getAttribute("data-l10n-args")),
    { tabCount: 2 },
    "The label reflects the number of selected tabs"
  );

  window.TabContextMenu.contextTab = null;
  gBrowser.clearMultiSelectedTabs();
  BrowserTestUtils.removeTab(tabOne);
  BrowserTestUtils.removeTab(tabTwo);
});
