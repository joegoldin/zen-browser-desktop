"use strict";

// Regression coverage for Ctrl+H (key_gotoHistory): the shortcut should open
// the history sidebar panel to the right of Zen's own tab sidebar, and
// toggle it closed again on a second press.
add_task(async function ctrl_h_toggles_history_sidebar() {
  const sidebarBox = document.getElementById("sidebar-box");
  ok(sidebarBox.hidden, "sidebar-box starts hidden");

  EventUtils.synthesizeKey("h", { accelKey: true }, window);
  await TestUtils.waitForCondition(
    () => !sidebarBox.hidden,
    "sidebar-box did not become visible after Ctrl+H"
  );

  is(
    SidebarController.currentID,
    "viewHistorySidebar",
    "Ctrl+H opens the history sidebar panel"
  );
  ok(SidebarController.isOpen, "SidebarController reports the sidebar open");
  const rect = sidebarBox.getBoundingClientRect();
  Assert.greater(rect.width, 0, "sidebar-box has a nonzero width once opened");
  is(
    SidebarController.browser?.currentURI?.spec,
    "chrome://browser/content/places/historySidebar.xhtml",
    "the history page is loaded into the sidebar panel"
  );

  EventUtils.synthesizeKey("h", { accelKey: true }, window);
  await TestUtils.waitForCondition(
    () => sidebarBox.hidden,
    "sidebar-box did not hide after a second Ctrl+H"
  );
});
