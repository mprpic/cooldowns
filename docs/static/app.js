// Progressive enhancement only: theme toggle, nav drawer, nav filter, collapsible
// groups, scrollspy, and copy buttons. Every section stays readable without it.
(() => {
  const root = document.documentElement;
  const $ = (sel, el = document) => el.querySelector(sel);
  const $$ = (sel, el = document) => [...el.querySelectorAll(sel)];
  const live = $("#live");
  const say = (msg) => {
    live.textContent = "";
    setTimeout(() => (live.textContent = msg), 60);
  };

  // Theme: three modes. "system" follows the OS; "light" and "dark" are remembered. The cycle goes
  // system -> the opposite of the OS theme -> the OS theme, so the first click always changes the look.
  const themeBtn = $(".theme-btn");
  const systemDark = matchMedia("(prefers-color-scheme: dark)");
  const mode = () => root.getAttribute("data-theme") || "system";
  const nextMode = () => {
    const os = systemDark.matches ? "dark" : "light";
    const order = ["system", os === "dark" ? "light" : "dark", os];
    return order[(order.indexOf(mode()) + 1) % order.length];
  };
  const labelTheme = () => {
    const label = `Theme: ${mode()}. Switch to ${nextMode()}.`;
    themeBtn.dataset.mode = mode();
    themeBtn.setAttribute("aria-label", label);
    themeBtn.setAttribute(themeBtn.hasAttribute("data-tip") ? "data-tip" : "title", label);
  };
  themeBtn.addEventListener("click", () => {
    const next = nextMode();
    if (next === "system") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", next);
    try {
      if (next === "system") localStorage.removeItem("theme");
      else localStorage.setItem("theme", next);
    } catch {}
    labelTheme();
  });
  systemDark.addEventListener("change", labelTheme);
  labelTheme();

  // Copy buttons on code blocks.
  const COPY_ICON =
    '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg>';
  for (const block of $$(".code")) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "copy-btn";
    btn.innerHTML = `${COPY_ICON}<span>Copy</span>`;
    const label = btn.lastChild;
    btn.addEventListener("click", async () => {
      const text = $("code", block).innerText.replace(/\n$/, "");
      let ok = true;
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        ok = false;
      }
      label.textContent = ok ? "Copied" : "Copy failed";
      say(ok ? "Copied to clipboard" : "Copy failed. Select the code and copy it manually.");
      setTimeout(() => (label.textContent = "Copy"), 1600);
    });
    $(".code-head", block).append(btn);
  }

  // Star and fork counts from the GitHub API, like a README badge. The result is cached for the
  // tab session to stay far below the API's limit of 60 unauthenticated requests per hour per IP.
  const repo = $(".repo[data-api]");
  if (repo) {
    const compact = (n) => (n >= 1000 ? `${(n / 1000).toFixed(1)}k`.replace(".0k", "k") : String(n));
    const show = ({ stars, forks }) => {
      if (!Number.isFinite(stars) || !Number.isFinite(forks)) return;
      $('[data-stat="stars"]', repo).textContent = compact(stars);
      $('[data-stat="forks"]', repo).textContent = compact(forks);
      $(".repo-stats", repo).hidden = false;
      repo.setAttribute("aria-label", `Source on GitHub: ${compact(stars)} stars, ${compact(forks)} forks`);
    };
    let cached = null;
    try {
      cached = JSON.parse(sessionStorage.getItem("repo-stats"));
    } catch {}
    if (cached) {
      show(cached);
    } else {
      fetch(repo.dataset.api, { headers: { Accept: "application/vnd.github+json" } })
        .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
        .then((d) => {
          const stats = { stars: d.stargazers_count, forks: d.forks_count };
          try {
            sessionStorage.setItem("repo-stats", JSON.stringify(stats));
          } catch {}
          show(stats);
        })
        .catch(() => {}); // Leave the counts hidden.
    }
  }

  // Tooltips from title attributes: a short delay for the first, then instant while warm.
  const tip = Object.assign(document.createElement("div"), { className: "tooltip", id: "tooltip" });
  tip.setAttribute("role", "tooltip");
  document.body.append(tip);
  let shownFor = null;
  let pendingFor = null;
  let openTimer = 0;
  let coolTimer = 0;
  let warm = false;
  const placeTip = (el) => {
    const at = el.getBoundingClientRect();
    const left = Math.min(at.left + at.width / 2 - tip.offsetWidth / 2, root.clientWidth - tip.offsetWidth - 4);
    let top = at.bottom + 6;
    if (top > root.clientHeight - tip.offsetHeight - 4) top = at.top - tip.offsetHeight - 6;
    tip.style.left = `${Math.round(Math.max(4, left))}px`;
    tip.style.top = `${Math.round(Math.max(4, top))}px`;
  };
  const showTip = (el) => {
    clearTimeout(coolTimer);
    pendingFor = null;
    tip.textContent = el.dataset.tip;
    tip.dataset.instant = String(warm);
    tip.style.left = tip.style.top = "0px";
    placeTip(el);
    tip.dataset.show = "true";
    el.setAttribute("aria-describedby", tip.id);
    shownFor = el;
    warm = true;
  };
  const hideTip = () => {
    clearTimeout(openTimer);
    pendingFor = null;
    if (!shownFor) return;
    tip.dataset.show = "false";
    tip.textContent = "";
    shownFor.removeAttribute("aria-describedby");
    shownFor = null;
    clearTimeout(coolTimer);
    coolTimer = setTimeout(() => (warm = false), 300);
  };
  const tipFor = (node) => node?.closest?.("[data-tip]");
  document.addEventListener("mouseover", (e) => {
    const el = tipFor(e.target);
    if (!el) {
      if (!shownFor?.matches(":focus-visible")) hideTip();
      return;
    }
    if (el === shownFor || el === pendingFor) return;
    clearTimeout(openTimer);
    if (warm) {
      showTip(el);
    } else {
      pendingFor = el;
      openTimer = setTimeout(() => showTip(el), 200);
    }
  });
  document.addEventListener("mouseleave", hideTip);
  document.addEventListener("focusin", (e) => {
    const el = tipFor(e.target);
    if (el?.matches(":focus-visible")) showTip(el);
  });
  document.addEventListener("focusout", hideTip);
  document.addEventListener("click", hideTip);
  document.addEventListener("toggle", hideTip, true);
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") hideTip();
  });
  const reflowTip = () => {
    if (!shownFor) return;
    const at = shownFor.getBoundingClientRect();
    if (at.bottom < 0 || at.top > root.clientHeight) hideTip();
    else placeTip(shownFor);
  };
  addEventListener("scroll", reflowTip, { passive: true });
  addEventListener("resize", reflowTip);
  const canHover = matchMedia("(hover: hover)");
  const adoptTitles = () => {
    for (const el of $$("[title]")) {
      el.dataset.tip = el.title;
      el.removeAttribute("title");
    }
  };
  const restoreTitles = () => {
    hideTip();
    for (const el of $$("[data-tip]")) {
      el.title = el.dataset.tip;
      delete el.dataset.tip;
    }
  };
  canHover.addEventListener("change", () => (canHover.matches ? adoptTitles() : restoreTitles()));
  if (canHover.matches) adoptTitles();

  const sidebar = $("#sidebar");
  if (!sidebar) return; // 404 page has no navigation.

  // Mobile drawer.
  const menuBtn = $(".menu-btn");
  const narrow = matchMedia("(max-width: 959px)");
  const isOpen = () => root.classList.contains("drawer-open");
  const setDrawer = (open) => {
    root.classList.toggle("drawer-open", open);
    menuBtn.setAttribute("aria-expanded", String(open));
    menuBtn.setAttribute("aria-label", open ? "Close navigation" : "Open navigation");
    for (const el of [$("main"), $(".site-footer")]) el.inert = open;
    if (open) sidebar.focus({ preventScroll: true });
  };
  menuBtn.addEventListener("click", () => setDrawer(!isOpen()));
  $(".backdrop").addEventListener("click", () => setDrawer(false));
  sidebar.addEventListener("click", (e) => {
    if (e.target.closest("a") && narrow.matches) setDrawer(false);
  });
  narrow.addEventListener("change", () => setDrawer(false));

  // Collapsible ecosystem groups.
  for (const btn of $$(".eco-toggle")) {
    btn.addEventListener("click", () => {
      const open = btn.getAttribute("aria-expanded") !== "true";
      btn.setAttribute("aria-expanded", String(open));
      btn.closest(".nav-eco").classList.toggle("collapsed", !open);
    });
  }

  // Nav filter: matches tool names, heading and subsection text, and ecosystem names.
  const filter = $("#nav-filter");
  const empty = $(".nav-empty");
  filter.addEventListener("input", () => {
    const q = filter.value.trim().toLowerCase();
    sidebar.classList.toggle("filtering", q !== "");
    let total = 0;
    for (const list of $$(".nav-list", sidebar)) {
      let shown = 0;
      for (const li of $$(":scope > li", list)) {
        let hit = !q || li.dataset.terms.includes(q);
        if (li.classList.contains("nav-eco")) {
          const groupHit = hit;
          for (const t of $$(":scope > ul > li", li)) {
            t.hidden = !(groupHit || t.dataset.terms.includes(q));
            hit ||= !t.hidden;
          }
        }
        li.hidden = !hit;
        shown += hit;
      }
      list.hidden = list.previousElementSibling.hidden = shown === 0;
      total += shown;
    }
    empty.hidden = total > 0;
  });
  filter.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      const first = $$("li:not([hidden]) > a", sidebar).find((a) => a.offsetParent !== null);
      if (first) {
        e.preventDefault();
        first.click();
      }
    } else if (e.key === "Escape" && filter.value) {
      e.stopPropagation();
      filter.value = "";
      filter.dispatchEvent(new Event("input"));
    }
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      if (isOpen()) {
        setDrawer(false);
        menuBtn.focus();
      }
    } else if (e.key === "/" && !e.ctrlKey && !e.metaKey && !e.altKey) {
      if (e.target.closest("input, textarea, select, [contenteditable]")) return;
      e.preventDefault();
      if (narrow.matches) setDrawer(true);
      filter.focus();
    }
  });

  // Scrollspy: highlight the current section in the sidebar and unfold its subsections.
  // Several tools can share one anchor (Other ecosystems); keep only the first link.
  const navLinks = new Map();
  for (const a of $$('a[href^="#"]', sidebar)) if (!navLinks.has(a.hash.slice(1))) navLinks.set(a.hash.slice(1), a);
  // Headings the sidebar doesn't link leave the previous section highlighted.
  const heads = $$(".doc :is(h1, h2, h3, h4)[id]").filter((h) => navLinks.has(h.id));
  const navScroll = $(".nav-scroll");
  const bar = $(".progress span");
  const keepVisible = (box, el) => {
    if (!el?.offsetParent || box.scrollHeight <= box.clientHeight) return;
    const b = box.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    if (r.top < b.top + 24 || r.bottom > b.bottom - 24) box.scrollTop += r.top - b.top - b.height / 3;
  };
  let active = null;
  const spy = () => {
    const y = (parseFloat(getComputedStyle(root).scrollPaddingTop) || 80) + 8;
    // At the very bottom, short final sections can't reach the top line; take the last visible heading.
    const limit = innerHeight + scrollY >= root.scrollHeight - 2 ? innerHeight : y;
    let h = heads[0];
    for (const el of heads) {
      if (el.getBoundingClientRect().top > limit) break;
      h = el;
    }
    if (h !== active) {
      active = h;
      for (const a of $$("[aria-current]", sidebar)) a.removeAttribute("aria-current");
      for (const li of $$(".nav-parent.open", sidebar)) li.classList.remove("open");
      const link = navLinks.get(h.id);
      link.setAttribute("aria-current", "location");
      link.closest(".nav-parent")?.classList.add("open");
      // In a collapsed group the link is hidden; keep the group's heading in view instead.
      keepVisible(navScroll, link.offsetParent ? link : link.closest(".nav-eco")?.querySelector(".eco-head a"));
    }
    const max = root.scrollHeight - innerHeight;
    bar.style.transform = `scaleX(${max > 0 ? Math.min(1, scrollY / max) : 0})`;
  };
  let queued = false;
  addEventListener(
    "scroll",
    () => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => {
        queued = false;
        spy();
      });
    },
    { passive: true },
  );
  addEventListener("resize", spy);
  spy();
})();
