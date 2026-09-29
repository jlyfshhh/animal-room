(function () {
  "use strict";

  var root = document.documentElement;
  var path = window.location.pathname;
  var product = path.split("/").filter(Boolean)[0] || "animal-room";
  var supportedProducts = ["bask", "shed", "haven"];
  root.dataset.product = supportedProducts.indexOf(product) >= 0 ? product : "animal-room";

  var storageKey = "animal-room-theme";
  var savedTheme = null;
  try {
    savedTheme = window.localStorage.getItem(storageKey);
  } catch (_error) {
    /* Storage can be disabled; dark remains the safe default. */
  }
  root.dataset.theme = savedTheme === "light" ? "light" : "dark";

  var themeColor = document.querySelector('meta[name="theme-color"]');
  if (!themeColor) {
    themeColor = document.createElement("meta");
    themeColor.name = "theme-color";
    document.head.appendChild(themeColor);
  }

  function updateThemeColor() {
    themeColor.content = root.dataset.theme === "light" ? "#f4f1e8" : "#101310";
  }

  var nav = document.querySelector("header nav");
  if (nav) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "theme-toggle";
    button.innerHTML =
      '<svg class="theme-moon" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M20 15.2A8.5 8.5 0 0 1 8.8 4a8.5 8.5 0 1 0 11.2 11.2Z" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>' +
      '<svg class="theme-sun" viewBox="0 0 24 24" fill="none" aria-hidden="true"><circle cx="12" cy="12" r="3.5" stroke-width="1.8"/><path d="M12 2v2M12 20v2M4.93 4.93l1.42 1.42M17.65 17.65l1.42 1.42M2 12h2M20 12h2M4.93 19.07l1.42-1.42M17.65 6.35l1.42-1.42" stroke-width="1.8" stroke-linecap="round"/></svg>';

    function updateButton() {
      var nextTheme = root.dataset.theme === "dark" ? "light" : "dark";
      button.setAttribute("aria-label", "Use " + nextTheme + " theme");
      button.title = "Use " + nextTheme + " theme";
      updateThemeColor();
    }

    button.addEventListener("click", function () {
      root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
      try {
        window.localStorage.setItem(storageKey, root.dataset.theme);
      } catch (_error) {
        /* The theme still works for this visit when storage is unavailable. */
      }
      updateButton();
    });

    nav.appendChild(button);
    updateButton();
  } else {
    updateThemeColor();
  }

  var main = document.querySelector("main") || document.querySelector("section");
  if (main) {
    if (!main.id) main.id = "main-content";
    var skip = document.createElement("a");
    skip.className = "skip-link";
    skip.href = "#" + main.id;
    skip.textContent = "Skip to content";
    document.body.insertBefore(skip, document.body.firstChild);
  }

  var pagePath = path.replace(/index\.html$/, "").replace(/\/$/, "") || "/";
  document.querySelectorAll("header nav a[href]").forEach(function (link) {
    try {
      var linkPath = new URL(link.href, window.location.origin).pathname
        .replace(/index\.html$/, "")
        .replace(/\/$/, "") || "/";
      if (linkPath === pagePath && !link.hash) link.setAttribute("aria-current", "page");
    } catch (_error) {
      /* Ignore malformed or non-HTTP links. */
    }
  });
})();
