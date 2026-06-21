// Shared SVG chrome helpers for the hand-rolled visualisations.

export const SVGNS = "http://www.w3.org/2000/svg"

// Two-color ramp (cool -> warm). Reads on both light and dark backgrounds, so it
// is intentionally theme-independent. Leaf/node fills use it; chrome does not.
const COLD = [70, 130, 200]
const HOT = [220, 70, 60]

export function colorFor(value, min, max) {
  const t = max > min ? (value - min) / (max - min) : 0
  const c = COLD.map((lo, i) => Math.round(lo + (HOT[i] - lo) * t))
  return `rgb(${c[0]}, ${c[1]}, ${c[2]})`
}

// Container/label chrome must contrast with the daisyUI base background, which
// flips with the theme.
export function themeChrome() {
  const dark = document.documentElement.getAttribute("data-theme") === "dark"
  return dark
    ? { fill: "rgba(255,255,255,0.05)", stroke: "rgba(255,255,255,0.22)", hover: "#f1f1f1", label: "#e6e6e6", link: "rgba(255,255,255,0.18)" }
    : { fill: "rgba(0,0,0,0.03)", stroke: "rgba(0,0,0,0.15)", hover: "#111", label: "#1a1a1a", link: "rgba(0,0,0,0.16)" }
}

// A floating tooltip, positioned at the cursor. Returns the element plus show/hide
// helpers; remember to `.remove()` the element on teardown.
export function makeTooltip() {
  const el = document.createElement("div")
  Object.assign(el.style, {
    position: "fixed",
    pointerEvents: "none",
    background: "rgba(17,17,17,.9)",
    color: "#fff",
    padding: "4px 8px",
    borderRadius: "4px",
    font: "12px sans-serif",
    opacity: "0",
    zIndex: "50",
    transition: "opacity .1s",
  })
  document.body.appendChild(el)
  return {
    el,
    show(event, html) {
      el.innerHTML = html
      el.style.left = `${event.clientX + 12}px`
      el.style.top = `${event.clientY + 12}px`
      el.style.opacity = "1"
    },
    hide() {
      el.style.opacity = "0"
    },
  }
}
