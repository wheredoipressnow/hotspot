// Captures Ctrl/Cmd+P globally and toggles the server-rendered fuzzy finder.
// The browser binds Ctrl/Cmd+P to print, so the default is prevented here.
export const Palette = {
  mounted() {
    this.onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === "p" || e.key === "P")) {
        e.preventDefault()
        this.pushEvent("toggle_palette", {})
      }
    }
    window.addEventListener("keydown", this.onKey)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey)
  },
}
