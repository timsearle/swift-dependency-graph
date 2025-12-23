# Graph Diffing

The `diff` subcommand compares two dependency graphs and reports what changed—added/removed nodes and edges.

## Usage

```bash
DependencyGraph diff <from> <to> [options]
```

| Argument | Description |
|----------|-------------|
| `<from>` | Baseline directory (e.g., previous version) |
| `<to>`   | Comparison directory (e.g., current version) |

### Options

| Option | Description |
|--------|-------------|
| `--format <format>` | Output format: `json` (default) or `text` |
| `--hide-transient` | Exclude transient dependencies from both graphs |
| `--show-targets` | Include Xcode build targets in both graphs |
| `--spm-edges` | Include SwiftPM package→package edges |
| `--stable-ids` / `--no-stable-ids` | Use stable node IDs (default: on) |

## How it works

1. Generates a JSON graph for each directory using the same flags
2. Extracts node IDs and edge pairs (`source->target`)
3. Computes set differences to find additions and removals
4. Outputs the diff in the requested format

## Output formats

### JSON (default)

```bash
DependencyGraph diff ./v1 ./v2 --format json
```

```json
{
  "metadata": {
    "format": "diff",
    "from": "./v1",
    "to": "./v2",
    "addedNodeCount": 2,
    "removedNodeCount": 1,
    "addedEdgeCount": 3,
    "removedEdges": 0
  },
  "addedNodes": ["newpackage", "anotherpackage"],
  "removedNodes": ["oldpackage"],
  "addedEdges": ["myapp->newpackage", "myapp->anotherpackage", "newpackage->anotherpackage"],
  "removedEdges": []
}
```

### Text

```bash
DependencyGraph diff ./v1 ./v2 --format text
```

```
addedNodes=2 removedNodes=1 addedEdges=3 removedEdges=0

Added nodes:
+ anotherpackage
+ newpackage

Removed nodes:
- oldpackage

Added edges:
+ myapp->newpackage
+ myapp->anotherpackage
+ newpackage->anotherpackage
```

## Stable IDs

For reliable diffing across machines and CI environments, use `--stable-ids` (enabled by default). This ensures node IDs are:

- Repository-relative (not absolute paths)
- Collision-free
- Deterministic across runs

Without stable IDs, project/target nodes may have machine-specific paths, causing false positives in diffs.

## Use cases

### CI: Detect dependency changes in PRs

```bash
# Compare main branch against PR branch
git checkout main
DependencyGraph graph . --format json > /tmp/main.json

git checkout pr-branch
DependencyGraph diff /tmp/main-checkout /tmp/pr-checkout --format text
```

### Audit: Track dependency growth over time

```bash
# Compare tagged releases
DependencyGraph diff ./releases/v1.0 ./releases/v2.0 --format json > v1-to-v2-diff.json
```

### Review: Understand what a refactor changed

```bash
# Before and after modularization
DependencyGraph diff ./before ./after --show-targets --format text
```

## JSON schema

The diff output follows `Schemas/dependency-graph.diff.schema.json`.
