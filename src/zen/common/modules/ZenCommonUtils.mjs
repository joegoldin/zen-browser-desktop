// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

window.gZenOperatingSystemCommonUtils = {
  kZenOSToSmallName: {
    WINNT: "windows",
    Darwin: "macos",
    Linux: "linux",
  },

  get currentOperatingSystem() {
    let os = Services.appinfo.OS;
    return this.kZenOSToSmallName[os];
  },
};

export class nsZenMultiWindowFeature {
  constructor() {}

  static get browsers() {
    return Services.wm.getEnumerator("navigator:browser");
  }

  static get currentBrowser() {
    return Services.wm.getMostRecentWindow("navigator:browser");
  }

  static get isActiveWindow() {
    return nsZenMultiWindowFeature.currentBrowser === window;
  }

  windowIsActive(browser) {
    return browser === nsZenMultiWindowFeature.currentBrowser;
  }

  async foreachWindowAsActive(callback) {
    if (!nsZenMultiWindowFeature.isActiveWindow) {
      return;
    }
    await this.forEachWindow(callback);
  }

  async forEachWindow(callback) {
    for (const browser of nsZenMultiWindowFeature.browsers) {
      try {
        if (browser.closed) {
          continue;
        }
        await callback(browser);
      } catch (e) {
        console.error(e);
      }
    }
  }

  forEachWindowSync(callback) {
    for (const browser of nsZenMultiWindowFeature.browsers) {
      try {
        if (browser.closed) {
          continue;
        }
        callback(browser);
      } catch (e) {
        console.error(e);
      }
    }
  }
}

export class nsZenDOMOperatedFeature {
  constructor() {
    var initBound = this.init.bind(this);
    document.addEventListener("DOMContentLoaded", initBound, { once: true });
  }
}

export class nsZenPreloadedFeature {
  constructor() {
    var initBound = this.init.bind(this);
    document.addEventListener("MozBeforeInitialXULLayout", initBound, {
      once: true,
    });
  }
}

window.gZenCommonActions = {
  copyCurrentURLToClipboard() {
    const [currentUrl, ClipboardHelper] = gURLBar.zenStrippedURI;
    let displaySpec = currentUrl.displaySpec;

    try {
      if (
        Services.prefs.getBoolPref("browser.urlbar.decodeURLsOnCopy", false) &&
        !currentUrl.schemeIs("data")
      ) {
        displaySpec = decodeURI(displaySpec);
      }
    } catch (e) {}

    ClipboardHelper.copyString(displaySpec);

    let button;
    /* eslint-disable mozilla/valid-services */
    if (Services.zen.canShare() && displaySpec.startsWith("http")) {
      button = {
        id: "zen-copy-current-url-button",
        command: event => {
          const buttonRect = event.target.getBoundingClientRect();
          /* eslint-disable mozilla/valid-services */
          Services.zen.share(
            currentUrl,
            "",
            "",
            buttonRect.left,
            window.innerHeight - buttonRect.bottom,
            buttonRect.width,
            buttonRect.height
          );
        },
      };
    }
    gZenUIManager.showToast("zen-copy-current-url-confirmation", {
      button,
      timeout: 3000,
    });
  },

  copyCurrentURLAsMarkdownToClipboard() {
    const [currentUrl, ClipboardHelper] = gURLBar.zenStrippedURI;
    const tabTitle = gBrowser.selectedTab.label;
    let displaySpec = currentUrl.displaySpec;

    try {
      if (
        Services.prefs.getBoolPref("browser.urlbar.decodeURLsOnCopy", false) &&
        !currentUrl.schemeIs("data")
      ) {
        displaySpec = decodeURI(displaySpec);
      }
    } catch (e) {}

    const markdownLink = `[${tabTitle}](${displaySpec})`;
    ClipboardHelper.copyString(markdownLink);

    gZenUIManager.showToast("zen-copy-current-url-as-markdown-confirmation", {
      timeout: 3000,
    });
  },

  // Copies the link(s) of the tab(s) targeted by the tab context menu. When the
  // context tab is part of a multi-selection, every selected tab's link is
  // copied, one per line.
  copyTabLinkToClipboard() {
    const contextTab = TabContextMenu.contextTab || gBrowser.selectedTab;
    if (!contextTab) {
      return;
    }
    const tabs = contextTab.multiselected
      ? gBrowser.selectedTabs
      : [contextTab];
    const decodeOnCopy = Services.prefs.getBoolPref(
      "browser.urlbar.decodeURLsOnCopy",
      false
    );

    const links = [];
    for (const tab of tabs) {
      const uri = tab.linkedBrowser?.currentURI;
      if (!uri) {
        continue;
      }
      let displaySpec = uri.displaySpec;
      try {
        if (decodeOnCopy && !uri.schemeIs("data")) {
          displaySpec = decodeURI(displaySpec);
        }
      } catch (e) {}
      links.push(displaySpec);
    }

    if (!links.length) {
      return;
    }

    Cc["@mozilla.org/widget/clipboardhelper;1"]
      .getService(Ci.nsIClipboardHelper)
      .copyString(links.join("\n"));

    gZenUIManager.showToast("zen-copy-tab-link-confirmation", {
      l10nArgs: { tabCount: links.length },
      timeout: 3000,
    });
  },

  throttle(f, delay) {
    let timer = 0;
    return function (...args) {
      clearTimeout(timer);
      timer = setTimeout(() => f.apply(this, args), delay);
    };
  },

  /**
   * Determines if a tab should be closed when navigating back with no history.
   * Only tabs with an owner that are not pinned and not empty are eligible.
   * Respects the user preference zen.tabs.close-on-back-with-no-history.
   *
   * @returns {boolean} True if the tab should be closed on back
   */
  shouldCloseTabOnBack() {
    if (
      !Services.prefs.getBoolPref(
        "zen.tabs.close-on-back-with-no-history",
        true
      )
    ) {
      return false;
    }
    const tab = gBrowser.selectedTab;
    return Boolean(
      tab.owner && !tab.pinned && !tab.hasAttribute("zen-empty-tab")
    );
  },
};
