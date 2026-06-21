import { hierarchy, pack } from "d3-hierarchy"

const SVGNS = "http://www.w3.org/2000/svg"
const SIZE = 932 // square layout in user units; viewBox scales it to the container
const LABEL_MIN_R = 26 // only label circles whose displayed radius exceeds this

// Two-color ramp for the author-count encoding (cool -> warm). Reads fine on both
// the light and dark backgrounds, so it is intentionally theme-independent.
const COLD = [70, 130, 200]
const HOT = [220, 70, 60]

function colorFor(value, min, max) {
  const t = max > min ? (value - min) / (max - min) : 0
  const c = COLD.map((lo, i) => Math.round(lo + (HOT[i] - lo) * t))
  return `rgb(${c[0]}, ${c[1]}, ${c[2]})`
}

// Knowledge map: a stable hue per author, so files owned by the same person share
// a color. No author (churn-free file) falls back to a neutral gray.
function authorColor(author) {
  if (!author) return "rgb(160,160,160)"
  let hash = 0
  for (let i = 0; i < author.length; i++) hash = (hash * 31 + author.charCodeAt(i)) | 0
  const hue = ((hash % 360) + 360) % 360
  return `hsl(${hue}, 55%, 55%)`
}

// Compact "time ago" label for an epoch-second timestamp, e.g. "3d", "5mo", "2y".
function relativeAge(epoch) {
  if (!epoch) return "—"
  const days = Math.floor(Date.now() / 1000 - epoch) / 86400
  if (days < 1) return "today"
  if (days < 30) return `${Math.floor(days)}d`
  if (days < 365) return `${Math.floor(days / 30)}mo`
  return `${Math.floor(days / 365)}y`
}

// Container/label chrome must contrast with the daisyUI base background, which
// flips with the theme. Leaf circles keep the ramp above.
function themeChrome() {
  const dark = document.documentElement.getAttribute("data-theme") === "dark"
  return dark
    ? { fill: "rgba(255,255,255,0.05)", stroke: "rgba(255,255,255,0.22)", hover: "#f1f1f1", label: "#e6e6e6" }
    : { fill: "rgba(0,0,0,0.03)", stroke: "rgba(0,0,0,0.15)", hover: "#111", label: "#1a1a1a" }
}

export const CirclePack = {
  mounted() {
    this.metric = "churn"
    this.colorBy = "author_count"
    this.labels = false
    this.focus = null

    this.svg = document.createElementNS(SVGNS, "svg")
    this.svg.setAttribute("viewBox", `0 0 ${SIZE} ${SIZE}`)
    this.svg.setAttribute("preserveAspectRatio", "xMidYMid meet")
    this.svg.style.width = "100%"
    this.svg.style.height = "100%"
    this.svg.style.cursor = "pointer"
    this.svg.style.display = "block"

    // CSS transitions on geometry props give us smooth zoom with no extra deps.
    // The hover stroke is themed via a CSS variable so it tracks dark/light.
    const style = document.createElementNS(SVGNS, "style")
    style.textContent =
      "circle{transition:cx .5s,cy .5s,r .5s,fill .3s}" +
      "circle.node--leaf:hover{stroke:var(--leaf-hover);stroke-width:2}" +
      // Flash a target circle so selecting it always gives feedback, even when the
      // zoom does not move (e.g. picking another file in the already-centered folder).
      "circle.node--flash{animation:node-flash .9s ease-out}" +
      "@keyframes node-flash{0%{stroke:var(--leaf-hover);stroke-width:6;stroke-opacity:1}" +
      "100%{stroke:var(--leaf-hover);stroke-width:0;stroke-opacity:0}}" +
      "text.node--label{pointer-events:none;text-anchor:middle;dominant-baseline:central;" +
      "font-family:sans-serif;transition:opacity .3s}"
    this.svg.appendChild(style)

    this.g = document.createElementNS(SVGNS, "g")
    this.svg.appendChild(this.g)
    this.el.appendChild(this.svg)

    this.tooltip = document.createElement("div")
    Object.assign(this.tooltip.style, {
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
    document.body.appendChild(this.tooltip)

    // Background click zooms back out to the root.
    this.svg.addEventListener("click", () => this.zoomTo(this.root))

    this.handleEvent("hotspot:tree", ({ tree, metric, color_by, labels }) => {
      this.metric = metric || "churn"
      this.colorBy = color_by || "author_count"
      this.labels = !!labels
      this.draw(tree)
    })

    // A row in the top-hotspots panel asks the chart to focus a path.
    this.handleEvent("hotspot:zoom", ({ path }) => {
      const node = this.findByPath(path)
      if (!node) return
      this.zoomTo(node.children ? node : node.parent || node)
      this.flash(node)
    })

    // Recolor chrome (not data) when the theme flips; root.html.heex updates
    // data-theme on this same event, registered earlier, so it runs first.
    this.onTheme = () => this.applyTheme()
    window.addEventListener("phx:set-theme", this.onTheme)

    // Ask the server for data now that the hook is live.
    this.pushEvent("hotspot:ready", {})
  },

  destroyed() {
    this.tooltip?.remove()
    window.removeEventListener("phx:set-theme", this.onTheme)
  },

  draw(tree) {
    this.g.replaceChildren()

    const root = hierarchy(tree)
      .sum((d) => (d.children ? 0 : d[this.metric] || 0))
      .sort((a, b) => (b.value || 0) - (a.value || 0))

    pack().size([SIZE, SIZE]).padding(3)(root)

    this.root = root
    this.focus = root

    const chrome = themeChrome()
    this.svg.style.setProperty("--leaf-hover", chrome.hover)

    const acs = root.leaves().map((l) => l.data.author_count || 0)
    const min = Math.min(0, ...acs)
    const max = Math.max(1, ...acs)

    for (const d of root.descendants()) {
      const circle = document.createElementNS(SVGNS, "circle")
      circle.setAttribute("cx", d.x)
      circle.setAttribute("cy", d.y)
      circle.setAttribute("r", d.r)

      if (d.children) {
        circle.setAttribute("fill", chrome.fill)
        circle.setAttribute("stroke", chrome.stroke)
        circle.addEventListener("click", (e) => {
          e.stopPropagation()
          this.zoomTo(d)
        })
        circle.addEventListener("mousemove", (e) => this.showTip(e, d))
        circle.addEventListener("mouseleave", () => this.hideTip())
      } else {
        circle.setAttribute("class", "node--leaf")
        const fill =
          this.colorBy === "main_author"
            ? authorColor(d.data.main_author)
            : colorFor(d.data.author_count || 0, min, max)
        circle.setAttribute("fill", fill)
        circle.addEventListener("mousemove", (e) => this.showTip(e, d))
        circle.addEventListener("mouseleave", () => this.hideTip())
        // Clicking a file drills into it: the server X-Rays its history.
        circle.addEventListener("click", (e) => {
          e.stopPropagation()
          if (d.data.path) this.pushEvent("xray", { path: d.data.path })
        })
      }

      d._circle = circle
      this.g.appendChild(circle)

      // Only folders get a standing label; file names would overlap, so they
      // stay hover-only (the tooltip).
      if (this.labels && d.children && d.data.name && d.data.name !== "root") {
        const label = document.createElementNS(SVGNS, "text")
        label.setAttribute("class", "node--label")
        label.setAttribute("fill", chrome.label)
        label.textContent = d.data.name
        d._label = label
        this.g.appendChild(label)
      }
    }

    this.zoomTo(root, false)
  },

  // Reposition every circle so `focus` fills the viewport (transitions animate it).
  zoomTo(focus, _animate = true) {
    if (!focus) return
    this.focus = focus
    const k = SIZE / (focus.r * 2)

    for (const d of this.root.descendants()) {
      const c = d._circle
      if (!c) continue
      const cx = (d.x - focus.x) * k + SIZE / 2
      const cy = (d.y - focus.y) * k + SIZE / 2
      const r = d.r * k
      c.setAttribute("cx", cx)
      c.setAttribute("cy", cy)
      c.setAttribute("r", r)
      this.placeLabel(d, cx, cy, r)
    }
  },

  // Labels only show for the folders one level below the current focus (revealed
  // as you zoom in) and only when big enough to read; font scales with the circle.
  placeLabel(d, cx, cy, r) {
    const label = d._label
    if (!label) return
    const atFocusLevel = this.focus && d.depth === this.focus.depth + 1
    if (!atFocusLevel || r < LABEL_MIN_R) {
      label.style.opacity = "0"
      return
    }
    const fontSize = Math.max(9, Math.min(r / 5, 18))
    // Sit just inside the top edge so a parent's label clears its children's.
    label.setAttribute("x", cx)
    label.setAttribute("y", cy - r + fontSize)
    label.setAttribute("font-size", fontSize)
    label.style.opacity = "1"
  },

  // Briefly outline a node's circle. Re-adding the class after a reflow restarts
  // the animation when the same node is picked twice in a row.
  flash(node) {
    const circle = node._circle
    if (!circle) return
    circle.classList.remove("node--flash")
    void circle.getBBox()
    circle.classList.add("node--flash")
  },

  // Find a node by its path: leaves carry `data.path`; containers are matched by
  // the path rebuilt from their ancestry.
  findByPath(path) {
    if (!this.root) return null
    return this.root.descendants().find((d) => {
      if (!d.children) return d.data.path === path
      const dir = d
        .ancestors()
        .reverse()
        .slice(1)
        .map((n) => n.data.name)
        .join("/")
      return dir === path
    })
  },

  // Recolor existing circles/labels for the current theme without recomputing layout.
  applyTheme() {
    if (!this.root) return
    const chrome = themeChrome()
    this.svg.style.setProperty("--leaf-hover", chrome.hover)
    for (const d of this.root.descendants()) {
      if (d.children && d._circle) {
        d._circle.setAttribute("fill", chrome.fill)
        d._circle.setAttribute("stroke", chrome.stroke)
      }
      if (d._label) d._label.setAttribute("fill", chrome.label)
    }
  },

  showTip(event, d) {
    let html
    if (d.children) {
      const files = d.leaves().length
      const churn = d.leaves().reduce((s, l) => s + (l.data.churn || 0), 0)
      const path = d
        .ancestors()
        .reverse()
        .slice(1)
        .map((n) => n.data.name)
        .join("/")
      html = `<strong>${path}/</strong><br>${files} files · churn ${churn}`
    } else {
      const churn = d.data.churn ?? 0
      const authors = d.data.author_count ?? 0
      const recency = d.data.recency_churn ?? 0
      const revisions = d.data.revisions ?? 0
      const changed = relativeAge(d.data.last_changed)
      const owner = d.data.main_author
        ? `<br>owner ${d.data.main_author.split("@")[0]} (${Math.round((d.data.ownership || 0) * 100)}%)`
        : ""
      html = `<strong>${d.data.path}</strong><br>churn ${churn} · ${revisions} revisions · authors ${authors}<br>recent ${recency} · changed ${changed}${owner}`
    }
    this.tooltip.innerHTML = html
    this.tooltip.style.left = `${event.clientX + 12}px`
    this.tooltip.style.top = `${event.clientY + 12}px`
    this.tooltip.style.opacity = "1"
  },

  hideTip() {
    this.tooltip.style.opacity = "0"
  },
}
