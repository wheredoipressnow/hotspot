// The scatter plot is server-rendered SVG. Delegate dot clicks to the LiveView
// (same "xray" event the circle-pack map uses) by reading the dot's path off a
// data attribute, so newly diffed dots stay clickable without rebinding.
export const Scatter = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      const dot = e.target.closest("[data-xray-path]")
      if (dot) this.pushEvent("xray", { path: dot.getAttribute("data-xray-path") })
    })
  },
}
