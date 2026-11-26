// Reel Media Player site.
// - Clips are Reel's real window with transparent surroundings: Safari gets HEVC-with-alpha (.mov), every
//   other browser VP9-with-alpha (.webm). They play only while on screen, and not at all for reduced motion.
// - Reveal-on-scroll, the hero desktop settling flat, and the pinned "big → tiny → on top" story.
// - The latest version on the download buttons.
(() => {
  const root = document.documentElement;
  root.classList.remove("no-js");
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Which transparent video this browser can show
  const ua = navigator.userAgent;
  const safari = /^((?!chrome|chromium|android|crios|fxios|edg|opr).)*safari/i.test(ua);
  const ext = safari ? "mov" : "webm";

  const clips = [...document.querySelectorAll("video[data-clip]")];
  if (!still) {
    const io = new IntersectionObserver(entries => {
      for (const e of entries) {
        const v = e.target;
        if (e.isIntersecting) {
          if (!v.src) { v.src = `assets/${v.dataset.clip}.${ext}`; }
          v.play().catch(() => {});
        } else if (v.src) {
          v.pause();
        }
      }
    }, { rootMargin: "200px 0px", threshold: 0.01 });
    clips.forEach(v => io.observe(v));
  }

  // Reveal on scroll
  const reveals = document.querySelectorAll(".reveal");
  if (still || !("IntersectionObserver" in window)) {
    reveals.forEach(el => el.classList.add("in"));
  } else {
    const ro = new IntersectionObserver(entries => {
      for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); ro.unobserve(e.target); }
    }, { threshold: 0.12 });
    reveals.forEach(el => ro.observe(el));
  }

  // Scroll-linked: the hero desktop tilts flat; the story pins and shrinks the window into the corner
  const desk = document.querySelector("[data-tilt]");
  const story = document.querySelector(".story");
  const floater = story && story.querySelector(".story-desk");
  const pinned = () => matchMedia("(min-width: 1001px)").matches;
  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const ease = t => t < .5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
  let ticking = false;
  function frame() {
    ticking = false;
    const vh = innerHeight;
    if (desk && !still) {
      const r = desk.getBoundingClientRect();
      const t = clamp((vh - r.top) / (vh * 0.9));          // 0 when it enters, 1 once it's well in view
      desk.style.setProperty("--tilt", (1 - ease(t)).toFixed(3));
    }
    if (story && floater) {
      if (!pinned() || still) { story.dataset.step = "1"; return; }
      const r = story.getBoundingClientRect();
      const p = clamp(-r.top / (r.height - vh));            // progress through the pinned section
      const shrink = ease(clamp((p - 0.18) / 0.4));
      const work = ease(clamp((p - 0.3) / 0.3));
      floater.style.setProperty("--shrink", shrink.toFixed(3));
      floater.style.setProperty("--work", work.toFixed(3));
      story.dataset.step = p < 0.3 ? "1" : p < 0.66 ? "2" : "3";
    }
  }
  const onScroll = () => { if (!ticking) { ticking = true; requestAnimationFrame(frame); } };
  addEventListener("scroll", onScroll, { passive: true });
  addEventListener("resize", onScroll);
  frame();

  // Latest version
  fetch("https://api.github.com/repos/kaioker/reel/releases/latest")
    .then(r => r.ok ? r.json() : null)
    .then(rel => {
      if (!rel || !rel.tag_name) return;
      document.querySelectorAll("[data-version]").forEach(el => { el.textContent = "Version " + rel.tag_name.replace(/^v/, ""); });
      document.querySelectorAll("[data-version-short]").forEach(el => { el.textContent = rel.tag_name; });
    })
    .catch(() => {});
})();
