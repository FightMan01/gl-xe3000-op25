/*
 * Runtime compatibility helpers for the OpenWrt GL UI port.
 *
 * The stock SDK4 application takes one system.get_status snapshot during
 * bootstrap.  Its getSystemStatusNow mutation is not consumed anywhere in
 * this particular compiled UI, so WAN/MWAN transitions after page load leave
 * the Internet cards stale until a full browser refresh.  Poll the small
 * status object and update the existing Vuex store in place.
 *
 * Besides keeping the cards current, the authenticated request doubles as a
 * lightweight session keepalive while the admin page is open.  No request is
 * made on the login/welcome page when there is no Admin-Token cookie.
 */
(function () {
	"use strict";

	var sequence = 900000;
	var requestRunning = false;
	var refreshCount = 0;

	function cookie(name) {
		var prefix = name + "=";
		var parts = document.cookie ? document.cookie.split(";") : [];
		for (var i = 0; i < parts.length; i++) {
			var part = parts[i].trim();
			if (part.indexOf(prefix) === 0) {
				return decodeURIComponent(part.substring(prefix.length));
			}
		}
		return "";
	}

	function store() {
		var root = document.getElementById("app");
		var vm = root && root.__vue__;
		if (vm && vm.$store) {
			return vm.$store;
		}

		/*
		 * Vue 2 replaces the #app mount node with the root component's
		 * rendered element.  On production builds that rendered element
		 * does not keep the original id, so looking up #app alone works
		 * during bootstrap but returns null afterwards.  Vue attaches the
		 * owning component as __vue__ to rendered component roots; find
		 * the first one backed by this application's Vuex store.
		 */
		var nodes = document.getElementsByTagName("*");
		for (var i = 0; i < nodes.length; i++) {
			vm = nodes[i].__vue__;
			if (vm && vm.$store) {
				return vm.$store;
			}
		}
		return null;
	}

	function forceVueRefresh(vuex) {
		/*
		 * Most views react to the Vuex mutations normally.  A few SDK4
		 * Internet-card computed properties, however, cache a value which
		 * combines systemStatus and mwanConfig.  If those two asynchronous
		 * replies cross, the card can retain an old offLineProto warning
		 * even though the store already says the interface is online.
		 * Force one cheap render pass after either half is refreshed.
		 */
		var nodes = document.getElementsByTagName("*");
		var seen = [];
		for (var i = 0; i < nodes.length; i++) {
			var vm = nodes[i].__vue__;
			if (vm && vm.$store === vuex && seen.indexOf(vm) < 0) {
				seen.push(vm);
				if (typeof vm.$forceUpdate === "function") {
					vm.$forceUpdate();
				}
			}
		}
	}

	function refreshStatus() {
		var token = cookie("Admin-Token");
		var vuex = store();
		if (!token || !vuex || requestRunning || document.hidden) {
			return;
		}

		requestRunning = true;
		var controller = typeof AbortController === "function"
			? new AbortController() : null;
		var timeout = controller
			? window.setTimeout(function () { controller.abort(); }, 4500)
			: null;
		var request = {
			jsonrpc: "2.0",
			id: sequence++,
			method: "call",
			params: [token, "system", "get_status", {}]
		};

		fetch("/rpc", {
			method: "POST",
			credentials: "same-origin",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(request),
			signal: controller ? controller.signal : undefined
		}).then(function (response) {
			return response.ok ? response.json() : null;
		}).then(function (reply) {
			if (reply && reply.result && !reply.error) {
				vuex.commit("updateSystemStatus", reply.result);
				/*
				 * Several SDK4 views also listen to this event mutation
				 * instead of watching systemStatus directly.  Commit both
				 * paths so an interface which becomes online after the
				 * initial page snapshot immediately loses its stale
				 * "connected, but Internet can't be accessed" warning.
				 */
				vuex.commit("getSystemStatusNow", 0);
				window.__glPortLastSystemStatus = reply.result;
				window.setTimeout(function () {
					forceVueRefresh(vuex);
				}, 0);
			}
		}).catch(function () {
			/* A regular UI request owns user-visible error handling. */
		}).finally(function () {
			if (timeout) {
				window.clearTimeout(timeout);
			}
			requestRunning = false;
		});

		/*
		 * The Internet view normally reads kmwan only once when it mounts.
		 * Refresh it occasionally as well: mode, priority and interface
		 * tracking can all change while the SPA remains open.
		 */
		refreshCount++;
		if (refreshCount % 3 === 0) {
			fetch("/rpc", {
				method: "POST",
				credentials: "same-origin",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({
					jsonrpc: "2.0",
					id: sequence++,
					method: "call",
					params: [token, "kmwan", "get_config", {}]
				})
			}).then(function (response) {
				return response.ok ? response.json() : null;
			}).then(function (reply) {
				if (reply && reply.result && !reply.error) {
					vuex.commit("updateMwanConfig", reply.result);
					window.__glPortLastMwanConfig = reply.result;
					window.setTimeout(function () {
						forceVueRefresh(vuex);
					}, 0);
				}
			}).catch(function () {});
		}
	}

	window.setTimeout(refreshStatus, 1500);
	window.setInterval(refreshStatus, 5000);
	document.addEventListener("visibilitychange", function () {
		if (!document.hidden) {
			refreshStatus();
		}
	});
})();
