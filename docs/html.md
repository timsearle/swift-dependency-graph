# HTML UI guide

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
