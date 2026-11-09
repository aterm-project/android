// Runs before Flutter, analytics or any router: removes a temporary-link or
// organization-join secret from the address bar and keeps it only in this
// closure until the app takes it once. The secret never reaches the server
// (fragments are not sent in requests or Referer headers).
(function () {
  "use strict";
  var captured = null;
  var hash = window.location.hash || "";
  var path = window.location.pathname || "/";
  var isShare = /^\/s\/[^/]+\/?$/.test(path) && hash.indexOf("#s1.") === 0;
  var isJoin = /^\/join\/?$/.test(path) && hash.indexOf("#o1.") === 0;
  if (isShare || isJoin) {
    captured = hash.substring(1);
    window.history.replaceState(null, "", path + window.location.search);
  } else if (/^\/(s\/[^/]+|join)\/?$/.test(path) && hash) {
    // Unknown fragment on a sharing route: drop it rather than letting the
    // app treat it as a route.
    window.history.replaceState(null, "", path + window.location.search);
  }
  Object.defineProperty(window, "atermiusTakeShareFragment", {
    value: function () {
      var value = captured;
      captured = null;
      return value;
    },
    writable: false,
    configurable: false,
    enumerable: false,
  });
})();
