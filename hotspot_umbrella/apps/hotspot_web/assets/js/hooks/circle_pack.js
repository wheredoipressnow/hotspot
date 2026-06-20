import { hierarchy, pack } from "d3-hierarchy"

const SVGNS = "http://www.w3.org/2000/svg"
const SIZE = 932 // square layout in user units; viewBox scales it to the container

// Two-color ramp for the author-count encoding (cool -> warm).
const COLD = [70, 130, 200]
const HOT = [220, 70, 60]

function colorFor(value, min, max) {
  const t = max > min ? (value - min) / (max - min) : 0
  const c = COLD.map((lo, i) => Math.round(lo + (HOT[i] - lo) * t))
  return `rgb(${c[0]}, ${c[1]}, ${c[2]})`
}

export const CirclePack = {
  mounted() {
    this.metric = "churn"
    this.focus = null

    this.svg = document.createElementNS(SVGNS, "svg")
    this.svg.setAttribute("viewBox", `0 0 ${SIZE} ${SIZE}`)
    this.svg.setAttribute("preserveAspectRatio", "xMidYMid meet")
    this.svg.style.width = "100%"
    this.svg.style.height = "100%"
    this.svg.style.cursor = "pointer"
    this.svg.style.display = "block"

    // CSS transitions on geometry props give us smooth zoom with no extra deps.
    const style = document.createElementNS(SVGNS, "style")
    style.textContent =
      "circle{transition:cx .5s,cy .5s,r .5s,fill .3s}" +
      "circle.node--leaf:hover{stroke:#111;stroke-width:2}"
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

    this.handleEvent("hotspot:tree", ({ tree, metric }) => {
      this.metric = metric || "churn"
      this.draw(tree)
    })

    // Ask the server for data now that the hook is live.
    this.pushEvent("hotspot:ready", {})
  },

  destroyed() {
    this.tooltip?.remove()
  },

  draw(tree) {
    this.g.replaceChildren()

    const root = hierarchy(tree)
      .sum((d) => (d.children ? 0 : d[this.metric] || 0))
      .sort((a, b) => (b.value || 0) - (a.value || 0))

    pack().size([SIZE, SIZE]).padding(3)(root)

    this.root = root
    this.focus = root

    const acs = root.leaves().map((l) => l.data.author_count || 0)
    const min = Math.min(0, ...acs)
    const max = Math.max(1, ...acs)

    for (const d of root.descendants()) {
      const circle = document.createElementNS(SVGNS, "circle")
      circle.setAttribute("cx", d.x)
      circle.setAttribute("cy", d.y)
      circle.setAttribute("r", d.r)

      if (d.children) {
        circle.setAttribute("fill", "rgba(0,0,0,0.03)")
        circle.setAttribute("stroke", "rgba(0,0,0,0.15)")
        circle.addEventListener("click", (e) => {
          e.stopPropagation()
          this.zoomTo(d)
        })
      } else {
        circle.setAttribute("class", "node--leaf")
        circle.setAttribute("fill", colorFor(d.data.author_count || 0, min, max))
        circle.addEventListener("mousemove", (e) => this.showTip(e, d))
        circle.addEventListener("mouseleave", () => this.hideTip())
        circle.addEventListener("click", (e) => e.stopPropagation())
      }

      d._circle = circle
      this.g.appendChild(circle)
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
      c.setAttribute("cx", (d.x - focus.x) * k + SIZE / 2)
      c.setAttribute("cy", (d.y - focus.y) * k + SIZE / 2)
      c.setAttribute("r", d.r * k)
    }
  },

  showTip(event, d) {
    const churn = d.data.churn ?? 0
    const authors = d.data.author_count ?? 0
    this.tooltip.innerHTML =
      `<strong>${d.data.path}</strong><br>churn ${churn} · authors ${authors}`
    this.tooltip.style.left = `${event.clientX + 12}px`
    this.tooltip.style.top = `${event.clientY + 12}px`
    this.tooltip.style.opacity = "1"
  },

  hideTip() {
    this.tooltip.style.opacity = "0"
  },
}
