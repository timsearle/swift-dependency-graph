.PHONY: build release test clean html html-fast html-full json dot gexf graphml analyze analyze-internal help

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
	@echo "  make json             - Export JSON graph format"
	@echo "  make dot              - Export Graphviz DOT format"
	@echo "  make gexf             - Export GEXF format (for Gephi)"
	@echo "  make graphml          - Alias for make gexf (legacy name)"
	@echo "  make analyze          - Run pinch point analysis"
	@echo "  make analyze-internal - Run analysis for internal modules only"
	@echo ""
	@echo "Variables:"
	@echo "  PROJECT=/path/to/root  (default: .)"
	@echo "  SHOW_TARGETS=1|0       (default: 1)"
	@echo "  HIDE_TRANSIENT=1|0     (default: 0)"
	@echo "  SPM_EDGES=1|0          (default: 0)"
	@echo "  SWIFTPM_JSON=1|0       (default: 0)"
	@echo "  EXTRA_ARGS=...         (passed through to CLI)"
	@echo ""
	@echo "Examples:"
	@echo "  make html-fast PROJECT=/path/to/MyApp"
	@echo "  make html-full PROJECT=/path/to/MyApp"
	@echo "  make html PROJECT=/path/to/MyApp SPM_EDGES=1"
	@echo "  make html PROJECT=/path/to/MyApp SWIFTPM_JSON=1"
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
	rm -f graph.html graph.json graph.gexf

# Default project path (override with PROJECT=...)
PROJECT ?= .

# Flags
SHOW_TARGETS ?= 1
HIDE_TRANSIENT ?= 0
SPM_EDGES ?= 0
SWIFTPM_JSON ?= 0
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
ifeq ($(SWIFTPM_JSON),1)
CLI_FLAGS += --swiftpm-json
endif

# Output targets
html: release
	.build/release/DependencyGraph "$(PROJECT)" --format html $(CLI_FLAGS) $(EXTRA_ARGS) > graph.html
	@echo "Generated graph.html"
	open graph.html

# Opinionated HTML journeys
html-fast: release
	HIDE_TRANSIENT=1 SHOW_TARGETS=1 SPM_EDGES=0 SWIFTPM_JSON=0 $(MAKE) --no-print-directory html PROJECT="$(PROJECT)" EXTRA_ARGS="$(EXTRA_ARGS)"

html-full: release
	HIDE_TRANSIENT=1 SHOW_TARGETS=1 SPM_EDGES=1 SWIFTPM_JSON=1 $(MAKE) --no-print-directory html PROJECT="$(PROJECT)" EXTRA_ARGS="$(EXTRA_ARGS)"

json: release
	.build/release/DependencyGraph "$(PROJECT)" --format json $(CLI_FLAGS) $(EXTRA_ARGS) > graph.json
	@echo "Generated graph.json"

dot: release
	.build/release/DependencyGraph "$(PROJECT)" --format dot $(CLI_FLAGS) $(EXTRA_ARGS) > graph.dot
	@echo "Generated graph.dot"

gexf: release
	.build/release/DependencyGraph "$(PROJECT)" --format gexf $(CLI_FLAGS) $(EXTRA_ARGS) > graph.gexf
	@echo "Generated graph.gexf (open with Gephi)"

graphml: gexf

# Analysis targets
analyze: release
	.build/release/DependencyGraph "$(PROJECT)" --format analyze $(CLI_FLAGS) $(EXTRA_ARGS)

analyze-internal: release
	.build/release/DependencyGraph "$(PROJECT)" --format analyze $(CLI_FLAGS) $(EXTRA_ARGS) --internal-only
