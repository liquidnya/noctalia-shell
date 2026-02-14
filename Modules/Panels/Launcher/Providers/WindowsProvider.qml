import QtQuick
import Quickshell
import qs.Commons
import qs.Services.Compositor

Item {
  id: root

  property string name: I18n.tr("common.windows")
  property var launcher: null
  property bool handleSearch: Settings.data.appLauncher.enableWindowsSearch
  property string supportedLayouts: "list"

  function init() {
    Logger.d("WindowsProvider", "Initialized");
  }

  // Check if this provider handles the command
  function handleCommand(searchText) {
    return searchText.startsWith(">win");
  }

  // Return available commands when user types ">"
  function commands() {
    return [
          {
            "name": ">win",
            "description": I18n.tr("launcher.providers.windows-search-description"),
            "icon": "app-window",
            "isTablerIcon": true,
            "isImage": false,
            "onActivate": function () {
              launcher.setSearchText(">win ");
            }
          },
          {
            "name": ">win[app_id]",
            "description": I18n.tr("launcher.providers.windows-search-description"),
            "icon": "app-window",
            "isTablerIcon": true,
            "isImage": false,
            "onActivate": function () {
              const prefix = ">win[";
              const suffix = "] ";
              launcher.setSearchText(`${prefix}${suffix}`);
              launcher.setSearchTextCursor(prefix.length);
            }
          }
        ];
  }

  function getResults(query) {
    if (!query)
      return [];

    let trimmed = query.trim();
    let searchTerm = "";
    let searchAppId = "";

    const isCommandMode = trimmed.startsWith(">win");

    // Handle command mode: ">win" or ">win <search>"
    if (isCommandMode) {
      // Extract search term after ">win "
      searchTerm = trimmed.substring(4);

      if (!searchTerm.startsWith("[")) {
        // search term is trimmed here and not above to distinguish between ">win[" and ">win ["
        searchTerm = searchTerm.trim();
      } else {
        // app_id is present
        const end = searchTerm.indexOf(']');
        if (end === -1) {
          // only filter by app_id
          searchAppId = searchTerm.substring(1).trim();
          searchTerm = "";
        } else {
          // filter by app_id and search term
          searchAppId = searchTerm.substring(1, end).trim();
          searchTerm = searchTerm.substring(end + 1).trim();
        }
      }

      // In command mode, show all windows if no search term
      if (searchTerm.length === 0 && searchAppId.length === 0) {
        return getAllWindows();
      }
    } else {
      // Regular search mode - require at least 2 chars
      if (trimmed.length < 2)
        return [];
      searchTerm = trimmed;
    }

    let items = [];
    let hasExactAppId = false;
    const searchKeys = ["title"];
    // do not search in appId with searchTerm if searchAppId is present
    if (searchAppId.length === 0) {
      searchKeys.push("appId");
    }
    const scoreFn = result => (result.obj.score + result.score) / 2;
    const mapResult = result => {
      const obj = result.obj;
      obj.score = result.score;
      return obj;
    };
    const newResult = (obj, score) => {
      const result = {
        obj,
        score
      };
      result.score = scoreFn(result);
      return result;
    };
    const exactMatchScore = 1;

    // Collect all windows from CompositorService
    for (let i = 0; i < CompositorService.windows.count; i++) {
      const win = CompositorService.windows.get(i);
      if (searchAppId.length !== 0 && win.appId === searchAppId) {
        hasExactAppId = true;
      }
      const obj = {
        "id": win.id,
        "title": win.title || "",
        "appId": win.appId || "",
        "workspaceId": win.workspaceId,
        "isFocused": win.isFocused,
        // Note that the score will be mutated
        "score": 1
      };
      // TODO: is searchText even needed anymore?
      obj.searchText = searchKeys.map(key => obj[key]).join(" ").toLowerCase();

      items.push(obj);
    }

    // Either filter by exact appId or fuzzy search on appId
    if (hasExactAppId) {
      items = items.filter(item => item.appId === searchAppId).map(item => mapResult(newResult(item, exactMatchScore)));
    }
    // Note that this is not in an else case on purpose
    // Otherwise the order of items would suddenly change when hasExactAppId is true
    if (searchAppId.length !== 0) {
      items = FuzzySort.go(searchAppId, items, {
                             keys: ["appId"],
                             scoreFn
                           }).map(mapResult);
    }

    // Fuzzy search on searchKeys
    if (searchTerm.length !== 0) {
      items = FuzzySort.go(searchTerm, items, {
                             keys: searchKeys,
                             limit: 10,
                             scoreFn
                           }).map(mapResult);
    }

    // Map to launcher items
    const launcherItems = [];
    for (let j = 0; j < items.length; j++) {
      const entry = items[j];

      // Get icon name from DesktopEntry if available, otherwise use appId
      let iconName = entry.appId;
      const appEntry = ThemeIcons.findAppEntry(entry.appId);
      if (appEntry && appEntry.icon) {
        iconName = appEntry.icon;
      }

      launcherItems.push({
                           "name": entry.title || entry.appId,
                           "description": entry.appId,
                           "icon": iconName || "application-x-executable",
                           "isTablerIcon": false,
                           "badgeIcon": "app-window",
                           "_score": entry.score,
                           "provider": root,
                           "windowId": entry.id,
                           "onActivate": createActivateHandler(entry)
                         });
    }

    return launcherItems;
  }

  function getAllWindows() {
    var launcherItems = [];

    for (var i = 0; i < CompositorService.windows.count; i++) {
      var win = CompositorService.windows.get(i);

      var iconName = win.appId;
      var appEntry = ThemeIcons.findAppEntry(win.appId);
      if (appEntry && appEntry.icon) {
        iconName = appEntry.icon;
      }

      launcherItems.push({
                           "name": win.title || win.appId,
                           "description": win.appId,
                           "icon": iconName || "application-x-executable",
                           "isTablerIcon": false,
                           "badgeIcon": "app-window",
                           "_score": 0,
                           "provider": root,
                           "windowId": win.id,
                           "onActivate": createActivateHandler({
                                                                 "id": win.id
                                                               })
                         });
    }

    return launcherItems;
  }

  function createActivateHandler(windowEntry) {
    return function () {
      if (launcher)
        launcher.close();

      Qt.callLater(() => {
                     // Find the actual window object to pass to focusWindow
                     for (var i = 0; i < CompositorService.windows.count; i++) {
                       var win = CompositorService.windows.get(i);
                       if (win.id === windowEntry.id) {
                         CompositorService.focusWindow(win);
                         break;
                       }
                     }
                   });
    };
  }
}
