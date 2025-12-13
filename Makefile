.PHONY: build release test clean html html-fast html-full html-profile html-profile-cold json dot gexf graphml analyze analyze-internal viewer-install viewer-start viewer help

# Default target
help:
	@echo "Usage:"
	@echo "  make build            - Build debug version"
	@echo "  make release          - Build release version"
	@echo "  make test             - Run tests"
	@echo "  make clean            - Clean build artifacts"
	@echo "  make html             - Generate HTML graph and open in browser"
	@echo "  make html-fast        - Recommended: targets + hide transient"
	@echo "  make html-full        - Full: targets + SwiftPM JSON + spm-edges"
	@echo "  make html-profile     - Like html, but prints timing breakdown (EXTRA_ARGS includes --profile)"
	@echo "  make html-profile-cold- Like html-profile, but clears this repo's .build first (tool-only cold start)"
	@echo "  make json             - Export JSON graph format"
	@echo "  make dot              - Export Graphviz DOT format"
	@echo "  make gexf             - Export GEXF format (for Gephi)"
	@echo "  make graphml          - Export GraphML format"
	@echo "  make analyze          - Run pinch point analysis"
	@echo "  make analyze-internal - Run analysis for internal modules only"
	@echo "  make viewer-install   - Install GraphML viewer deps (../graphml-viewer)"
	@echo "  make viewer-start     - Start GraphML viewer (http://localhost:4200)"
	@echo "  make viewer           - Open viewer in browser (starts if needed)"
	@echo ""
	@echo "Variables:"
	@echo "  PROJECT=/path/to/root  (default: .)"
	@echo "  SHOW_TARGETS=1|0       (default: 1)"
	@echo "  HIDE_TRANSIENT=1|0     (default: 0)"
	@echo "  SPM_EDGES=1|0          (default: 0)"
	@echo "  SWIFTPM_JSON=1|0       (default: 1; 0 is deprecated)"
	@echo "  EXTRA_ARGS=...         (passed through to CLI)"
	@echo ""
	@echo "Examples:"
	@echo "  make html-fast PROJECT=/path/to/MyApp"
	@echo "  make html-full PROJECT=/path/to/MyApp"
	@echo "  make html PROJECT=/path/to/MyApp SPM_EDGES=1"
	@echo "  make html PROJECT=/path/to/MyApp SWIFTPM_JSON=0    # DEPRECATED regex fallback"
	@echo "  make json PROJECT=/path/to/MyApp HIDE_TRANSIENT=1"

# Build targets
build:
	swift build

release:
	swift build -c release

test:
	swift test

clean:
	swift package clean
	rm -f graph.html graph.json graph.gexf graph.graphml graph.dot

# Default project path (override with PROJECT=...)
PROJECT ?= .

# Flags
SHOW_TARGETS ?= 1
HIDE_TRANSIENT ?= 0
SPM_EDGES ?= 0
SWIFTPM_JSON ?= 1
EXTRA_ARGS ?=

CLI_FLAGS :=
ifeq ($(SHOW_TARGETS),1)
CLI_FLAGS += --show-targets
endif
ifeq ($(HIDE_TRANSIENT),1)
CLI_FLAGS += --hide-transient
endif
ifeq ($(SPM_EDGES),1)
CLI_FLAGS += --spm-edges
endif
ifeq ($(SWIFTPM_JSON),0)
CLI_FLAGS += --no-swiftpm-json
endif

# Output targets
html: release
	.build/release/DependencyGraph "$(PROJECT)" --format html $(CLI_FLAGS) $(EXTRA_ARGS) > graph.html
	@echo "Generated graph.html"
	open graph.html

# Opinionated HTML journeys
html-fast: release
	HIDE_TRANSIENT=1 SHOW_TARGETS=1 SPM_EDGES=0 SWIFTPM_JSON=1 $(MAKE) --no-print-directory html PROJECT="$(PROJECT)" EXTRA_ARGS="$(EXTRA_ARGS)"

html-full: release
	HIDE_TRANSIENT=1 SHOW_TARGETS=1 SPM_EDGES=1 SWIFTPM_JSON=1 $(MAKE) --no-print-directory html PROJECT="$(PROJECT)" EXTRA_ARGS="$(EXTRA_ARGS)"

html-profile: release
	$(MAKE) --no-print-directory html PROJECT="$(PROJECT)" SHOW_TARGETS="$(SHOW_TARGETS)" HIDE_TRANSIENT="$(HIDE_TRANSIENT)" SPM_EDGES="$(SPM_EDGES)" SWIFTPM_JSON="$(SWIFTPM_JSON)" EXTRA_ARGS="--profile $(EXTRA_ARGS)"

html-profile-cold: clean
	rm -rf .build
	$(MAKE) --no-print-directory html-profile PROJECT="$(PROJECT)" SHOW_TARGETS="$(SHOW_TARGETS)" HIDE_TRANSIENT="$(HIDE_TRANSIENT)" SPM_EDGES="$(SPM_EDGES)" SWIFTPM_JSON="$(SWIFTPM_JSON)" EXTRA_ARGS="$(EXTRA_ARGS)"

json: release
	.build/release/DependencyGraph "$(PROJECT)" --format json $(CLI_FLAGS) $(EXTRA_ARGS) > graph.json
	@echo "Generated graph.json"

dot: release
	.build/release/DependencyGraph "$(PROJECT)" --format dot $(CLI_FLAGS) $(EXTRA_ARGS) > graph.dot
	@echo "Generated graph.dot"

gexf: release
	.build/release/DependencyGraph "$(PROJECT)" --format gexf $(CLI_FLAGS) $(EXTRA_ARGS) > graph.gexf
	@echo "Generated graph.gexf (open with Gephi)"

graphml: release
	.build/release/DependencyGraph "$(PROJECT)" --format graphml $(CLI_FLAGS) $(EXTRA_ARGS) > graph.graphml
	@echo "Generated graph.graphml"

# Analysis targets
analyze: release
	.build/release/DependencyGraph "$(PROJECT)" --format analyze $(CLI_FLAGS) $(EXTRA_ARGS)

analyze-internal: release
	.build/release/DependencyGraph "$(PROJECT)" --format analyze $(CLI_FLAGS) $(EXTRA_ARGS) --internal-only

# GraphML viewer (external repo)
VIEWER_DIR ?= ../graphml-viewer

viewer-install:
	@cd "$(VIEWER_DIR)" && (node -v >/dev/null 2>&1 || (echo "Node.js is not available/working." && exit 1))
	@cd "$(VIEWER_DIR)" && node -e 'const m=+process.versions.node.split(".")[0]; if(m!==14){console.error("GraphML viewer requires Node 14.x (Angular 8 / websocket-driver uses http_parser). Current: "+process.versions.node+". Install via nvm/asdf/volta and retry."); process.exit(1)}'
	cd "$(VIEWER_DIR)" && npm install --legacy-peer-deps

viewer-start:
	@cd "$(VIEWER_DIR)" && (node -v >/dev/null 2>&1 || (echo "Node.js is not available/working." && exit 1))
	@cd "$(VIEWER_DIR)" && node -e 'const m=+process.versions.node.split(".")[0]; if(m!==14){console.error("GraphML viewer requires Node 14.x (Angular 8 / websocket-driver uses http_parser). Current: "+process.versions.node+". Install via nvm/asdf/volta and retry."); process.exit(1)}'
	cd "$(VIEWER_DIR)" && npm start

viewer:
	@open http://localhost:4200/ || true
