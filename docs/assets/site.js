// Reel Media Player site: play the clips only while they're on screen (and not at all for people who ask for
// less motion), and show the latest version on the download buttons.
(() => {
  const still = window.matchMedia("(prefers-reduced-motion: reduce)");
  const clips = document.querySelectorAll("video");
  if (still.matches) {
    clips.forEach(v => { v.removeAttribute("autoplay"); v.pause(); });
  } else if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(entries => {
      for (const e of entries) {
        if (e.isIntersecting) e.target.play().catch(() => {}); else e.target.pause();
      }
    }, { threshold: 0.25 });
    clips.forEach(v => io.observe(v));
  }

  fetch("https://api.github.com/repos/kaioker/reel/releases/latest")
    .then(r => r.ok ? r.json() : null)
    .then(rel => {
      if (!rel || !rel.tag_name) return;
      document.querySelectorAll("[data-version]").forEach(el => { el.textContent = "Version " + rel.tag_name.replace(/^v/, ""); });
      document.querySelectorAll("[data-version-short]").forEach(el => { el.textContent = rel.tag_name; });
    })
    .catch(() => {});
})();
