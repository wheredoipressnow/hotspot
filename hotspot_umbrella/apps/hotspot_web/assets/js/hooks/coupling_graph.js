import {
  forceSimulation,
  forceManyBody,
  forceLink,
  forceCenter,
  forceCollide,
} from "d3-force"
import { SVGNS, colorFor, themeChrome, makeTooltip } from "./svg_util.js"

const SIZE = 1000 // square layout in user units; viewBox scales it to the container
const R_MIN = 5
const R_MAX = 16
const LABEL_MIN_DEGREE = 3 // standing labels for hubs; everything else is hover-only

// Force-directed "cloud" of a file's temporal-coupling neighbourhood. Nodes are
// files; an edge means the two change together; node color ramps with `degree`
// (how often a file shows up as a coupling target: a hub runs hot). Data arrives
// from the server via the `coupling:graph` event.
export const CouplingGraph = {
  mounted() {
    this.svg = document.createElementNS(SVGNS, "svg")
    this.svg.setAttribute("viewBox", `0 0 ${SIZE} ${SIZE}`)
    this.svg.setAttribute("preserveAspectRatio", "xMidYMid meet")
    this.svg.style.width = "100%"
    this.svg.style.height = "100%"
    this.svg.style.display = "block"

    const style = document.createElementNS(SVGNS, "style")
    style.textContent =
      "circle.cg-node{cursor:pointer;transition:fill .3s}" +
      "circle.cg-node:hover{stroke:var(--cg-hover);stroke-width:2}" +
      "text.cg-label{pointer-events:none;text-anchor:middle;dominant-baseline:central;" +
      "font-family:sans-serif;transition:opacity .3s}"
    this.svg.appendChild(style)

    this.links = document.createElementNS(SVGNS, "g")
    this.nodes = document.createElementNS(SVGNS, "g")
    this.labels = document.createElementNS(SVGNS, "g")
    this.svg.append(this.links, this.nodes, this.labels)
    this.el.appendChild(this.svg)

    this.tip = makeTooltip()

    this.handleEvent("coupling:graph", (graph) => this.draw(graph))

    this.onTheme = () => this.applyTheme()
    window.addEventListener("phx:set-theme", this.onTheme)

    // Ask the server for data now that the hook is live.
    this.pushEvent("coupling:ready", {})
  },

  destroyed() {
    this.sim?.stop()
    this.tip?.el.remove()
    window.removeEventListener("phx:set-theme", this.onTheme)
  },

  draw({ root, nodes, edges }) {
    this.sim?.stop()
    this.links.replaceChildren()
    this.nodes.replaceChildren()
    this.labels.replaceChildren()
    if (!nodes || nodes.length === 0) return

    this.root = root
    // d3-force mutates the data it's given, so hand it fresh copies and key links
    // by id (the server sends source/target as paths).
    const data = nodes.map((n) => ({ ...n }))
    const ids = new Set(data.map((n) => n.id))
    const links = (edges || [])
      .filter((e) => ids.has(e.source) && ids.has(e.target))
      .map((e) => ({ ...e }))

    const degrees = data.map((n) => n.degree)
    const maxDeg = Math.max(1, ...degrees)
    const chrome = themeChrome()
    this.svg.style.setProperty("--cg-hover", chrome.hover)

    const radius = (n) => (n.id === root ? R_MAX + 4 : R_MIN + (R_MAX - R_MIN) * (n.degree / maxDeg))

    for (const link of links) {
      const line = document.createElementNS(SVGNS, "line")
      line.setAttribute("stroke", chrome.link)
      line.setAttribute("stroke-width", 1 + link.weight * 2)
      link._line = line
      this.links.appendChild(line)
    }

    for (const n of data) {
      const circle = document.createElementNS(SVGNS, "circle")
      circle.setAttribute("class", "cg-node")
      circle.setAttribute("r", radius(n))
      circle.setAttribute("fill", n.id === root ? chrome.hover : colorFor(n.degree, 0, maxDeg))
      circle.setAttribute("stroke", chrome.stroke)
      circle.addEventListener("mousemove", (e) => this.showTip(e, n))
      circle.addEventListener("mouseleave", () => this.tip.hide())
      // Click re-roots the cloud on that file.
      circle.addEventListener("click", () => this.pushEvent("recenter", { path: n.id }))
      this.attachDrag(circle, n)
      n._circle = circle
      this.nodes.appendChild(circle)

      if (n.id === root || n.degree >= LABEL_MIN_DEGREE) {
        const label = document.createElementNS(SVGNS, "text")
        label.setAttribute("class", "cg-label")
        label.setAttribute("fill", chrome.label)
        label.setAttribute("font-size", n.id === root ? 14 : 11)
        label.textContent = baseName(n.id)
        n._label = label
        this.labels.appendChild(label)
      }
    }

    this.data = data
    this.linkData = links

    this.sim = forceSimulation(data)
      .force("charge", forceManyBody().strength(-260))
      .force(
        "link",
        forceLink(links)
          .id((d) => d.id)
          // Stronger coupling => shorter spring => closer together.
          .distance((l) => 40 + (1 - l.weight) * 140)
          .strength((l) => 0.2 + l.weight * 0.6),
      )
      .force("center", forceCenter(SIZE / 2, SIZE / 2))
      .force("collide", forceCollide().radius((n) => radius(n) + 4))
      .on("tick", () => this.tick())

    // Pin the root near the middle so the cloud spreads around it.
    const r = data.find((n) => n.id === root)
    if (r) {
      r.fx = SIZE / 2
      r.fy = SIZE / 2
    }
  },

  tick() {
    for (const l of this.linkData) {
      l._line.setAttribute("x1", l.source.x)
      l._line.setAttribute("y1", l.source.y)
      l._line.setAttribute("x2", l.target.x)
      l._line.setAttribute("y2", l.target.y)
    }
    for (const n of this.data) {
      n._circle.setAttribute("cx", n.x)
      n._circle.setAttribute("cy", n.y)
      if (n._label) {
        n._label.setAttribute("x", n.x)
        n._label.setAttribute("y", n.y - parseFloat(n._circle.getAttribute("r")) - 7)
      }
    }
  },

  // Pointer drag to reposition a node; releasing unpins it (except the root, which
  // stays pinned to keep the layout anchored). Raw pointer events avoid a d3-drag dep.
  attachDrag(circle, n) {
    let dragging = false
    const move = (e) => {
      if (!dragging) return
      const p = this.toUser(e)
      n.fx = p.x
      n.fy = p.y
      this.sim?.alphaTarget(0.2).restart()
    }
    const up = () => {
      dragging = false
      if (n.id !== this.root) {
        n.fx = null
        n.fy = null
      }
      this.sim?.alphaTarget(0)
      window.removeEventListener("pointermove", move)
      window.removeEventListener("pointerup", up)
    }
    circle.addEventListener("pointerdown", (e) => {
      e.stopPropagation()
      dragging = true
      window.addEventListener("pointermove", move)
      window.addEventListener("pointerup", up)
    })
  },

  // Map a client-space pointer event to the SVG's user-coordinate space.
  toUser(event) {
    const rect = this.svg.getBoundingClientRect()
    const side = Math.min(rect.width, rect.height)
    // preserveAspectRatio=xMidYMid meet: the viewBox is centered in the larger axis.
    const ox = rect.left + (rect.width - side) / 2
    const oy = rect.top + (rect.height - side) / 2
    return {
      x: ((event.clientX - ox) / side) * SIZE,
      y: ((event.clientY - oy) / side) * SIZE,
    }
  },

  showTip(event, n) {
    const role = n.id === this.root ? "root" : `${n.degree} link${n.degree === 1 ? "" : "s"}`
    this.tip.show(event, `<strong>${n.id}</strong><br>${role}`)
  },

  applyTheme() {
    if (!this.data) return
    const chrome = themeChrome()
    this.svg.style.setProperty("--cg-hover", chrome.hover)
    const maxDeg = Math.max(1, ...this.data.map((n) => n.degree))
    for (const n of this.data) {
      n._circle.setAttribute("fill", n.id === this.root ? chrome.hover : colorFor(n.degree, 0, maxDeg))
      n._circle.setAttribute("stroke", chrome.stroke)
      if (n._label) n._label.setAttribute("fill", chrome.label)
    }
    for (const l of this.linkData) l._line.setAttribute("stroke", chrome.link)
  },
}

function baseName(path) {
  const i = path.lastIndexOf("/")
  return i === -1 ? path : path.slice(i + 1)
}
