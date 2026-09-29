(function () {
  "use strict";
  var root = document.documentElement;
  var product = window.location.pathname.split("/").filter(Boolean)[0] || "animal-room";
  root.dataset.product = ["bask", "shed", "haven"].indexOf(product) >= 0 ? product : "animal-room";
  try {
    root.dataset.theme = window.localStorage.getItem("animal-room-theme") === "light" ? "light" : "dark";
  } catch (_error) {
    root.dataset.theme = "dark";
  }
})();
