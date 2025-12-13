# HTML UI guide

## Offline mode (no CDN)

By default the HTML output loads `vis-network` from a CDN.

To generate HTML that does **not** reference a CDN, provide a local copy of `vis-network.min.js`:

```bash
.build/release/DependencyGraph graph /path/to/root --format html \
  --html-offline --vis-network-js /path/to/vis-network.min.js \
  > graph.html
```

## Interactions

- **Pan**: drag to move the view
- **Zoom**: scroll to zoom in/out
- **Search**: autocomplete nodes; select one to highlight + focus
- **Drag nodes**: reposition nodes manually
- **Click node**: shows details in the sidebar
- **Double-click**: navigate to dependencies subgraph
- **Dependencies ↓**: view what a node depends on
- **Dependents ↑**: view what depends on a node
- **Breadcrumbs**: navigate back through views
- **Toggle transient**: show/hide transient dependencies dynamically (when present)
- **Reset view**: fit the whole graph on screen

## Node colors

| Color | Node type |
|------|-----------|
| Blue | Xcode Project |
| Green | Build Target |
| Yellow | Internal Package (local, you control) |
| Dark Gray | External Package (remote) |
| Light Gray (dashed) | Transient (indirect dependency) |
