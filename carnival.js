/*
 * carnival.js — 社团嘉年华定制层
 *
 * 作用：读取同目录下的 carnival.config.json，把标语渲染到页面左下角。
 * 设计原则：只做「加法」，不碰游戏本体逻辑，确保改坏配置也不会影响游戏运行。
 *
 * 同学要改的内容在 carnival.config.json 里，不需要动这个文件。
 */
(function () {
	"use strict";

	var FALLBACK = {
		slogan: "开源软件社 · 社团嘉年华",
		subtitle: "扫码即玩 · 30 秒冲榜",
		accent: "#4099ff"
	};

	/*
	 * 原版游戏结算页带 Facebook / Twitter 分享按钮和 App Store 角标。
	 * 在国内这些链接都打不开，点了没反应会让摊位显得不专业，直接隐藏。
	 * 用 CSS 隐藏而非删除 DOM，方便日后需要时恢复。
	 */
	function hideDeadLinks() {
		try {
			var css = document.createElement("style");
			css.textContent = [
				"#socialShare{display:none !important}",
				".rrssb-buttons{display:none !important}",
				"#badges{display:none !important}"
			].join("");
			document.head.appendChild(css);

			/* 只靠 CSS 隐藏不够：元素里的 <img> 浏览器仍会去请求。
			   直接从 DOM 摘掉，省掉这部分请求。 */
			var kill = ["socialShare", "badges"];
			for (var i = 0; i < kill.length; i++) {
				var el = document.getElementById(kill[i]);
				if (el && el.parentNode) {
					el.parentNode.removeChild(el);
				}
			}
			var btns = document.querySelector(".rrssb-buttons");
			if (btns && btns.parentNode) {
				btns.parentNode.removeChild(btns);
			}
		} catch (e) {
			/* 忽略 */
		}
	}

	/*
	 * 结算页加一个通往贡献者墙的入口。
	 * 放在原分享按钮腾出来的位置，且只在结算页出现——
	 * 游玩过程中不插任何可点击元素，避免挡住旋转六边形的触控区域。
	 */
	function addWallLink() {
		try {
			var box = document.getElementById("bottomContainer");
			if (!box || document.getElementById("carnivalWallLink")) {
				return;
			}
			var a = document.createElement("a");
			a.id = "carnivalWallLink";
			a.href = "wall.html";
			a.textContent = "看看谁上墙了 →";
			a.style.cssText = [
				"display:inline-block",
				"margin-top:12px",
				"padding:7px 18px",
				"border-radius:20px",
				"background:rgba(88,166,255,.14)",
				"border:1px solid rgba(88,166,255,.45)",
				"color:#79c0ff",
				"font-size:12px",
				"text-decoration:none",
				"letter-spacing:.02em"
			].join(";");
			box.appendChild(a);
		} catch (e) {
			/* 忽略 */
		}
	}

	function render(cfg) {
		try {
			document.title = cfg.slogan + " · Hextris";

			if (document.getElementById("carnivalMark")) {
				return;
			}

			var box = document.createElement("div");
			box.id = "carnivalMark";
			box.setAttribute("aria-hidden", "true");
			box.style.cssText = [
				"position:fixed",
				"left:10px",
				"bottom:10px",
				"z-index:9999",
				"pointer-events:none",
				"display:flex",
				"align-items:center",
				"gap:7px",
				"max-width:calc(100vw - 20px)",
				"padding:5px 12px 5px 9px",
				"border-radius:20px",
				"background:rgba(35,35,35,.62)",
				"color:#ecf0f1",
				"font-family:'Exo',system-ui,-apple-system,'PingFang SC','Hiragino Sans GB','Microsoft YaHei',sans-serif",
				"font-size:11px",
				"line-height:1.4",
				"letter-spacing:.02em",
				"white-space:nowrap",
				"overflow:hidden"
			].join(";");

			var dot = document.createElement("span");
			dot.style.cssText = "flex:none;width:7px;height:7px;border-radius:50%;background:" +
				(/^#[0-9a-fA-F]{3,8}$/.test(cfg.accent) ? cfg.accent : FALLBACK.accent);
			box.appendChild(dot);

			var txt = document.createElement("span");
			txt.style.cssText = "overflow:hidden;text-overflow:ellipsis";
			txt.textContent = cfg.subtitle ? cfg.slogan + " · " + cfg.subtitle : cfg.slogan;
			box.appendChild(txt);

			document.body.appendChild(box);
		} catch (e) {
			/* 定制层出错绝不能影响游戏 */
		}
	}

	function load() {
		hideDeadLinks();
		addWallLink();
		if (!window.fetch) {
			render(FALLBACK);
			return;
		}
		fetch("carnival.config.json", { cache: "no-store" })
			.then(function (r) {
				return r.ok ? r.json() : FALLBACK;
			})
			.then(function (cfg) {
				var merged = {};
				var k;
				for (k in FALLBACK) {
					if (Object.prototype.hasOwnProperty.call(FALLBACK, k)) {
						merged[k] = FALLBACK[k];
					}
				}
				for (k in cfg) {
					if (Object.prototype.hasOwnProperty.call(cfg, k) && cfg[k]) {
						merged[k] = cfg[k];
					}
				}
				render(merged);
			})
			.catch(function () {
				render(FALLBACK);
			});
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", load);
	} else {
		load();
	}
})();
