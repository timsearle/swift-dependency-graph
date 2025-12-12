.PHONY: build release test clean html json gexf graphml analyze analyze-internal help

# Default target
help:
	@echo "Usage:"
	@echo "  make build            - Build debug version"
	@echo "  make release          - Build release version"
	@echo "  make test             - Run tests"
	@echo "  make clean            - Clean build artifacts"
	@echo "  make html             - Generate HTML graph and open in browser"
	@echo "  make json             - Export JSON graph format"
	@echo "  make gexf             - Export GEXF format (for Gephi)"
	@echo "  make graphml          - Alias for make gexf (legacy name)"
	@echo "  make analyze          - Run pinch point analysis"
	@echo "  make analyze-internal - Run analysis for internal modules only"
	@echo ""
	@echo "Set PROJECT=/path/to/ios-project to analyze a specific project"
	@echo "Example: make html PROJECT=/path/to/MyApp"

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

# Output targets
html: release
	.build/release/DependencyGraph "$(PROJECT)" --format html --show-targets > graph.html
	@echo "Generated graph.html"
	open graph.html

json: release
	.build/release/DependencyGraph "$(PROJECT)" --format json --show-targets > graph.json
	@echo "Generated graph.json"

gexf: release
	.build/release/DependencyGraph "$(PROJECT)" --format gexf --show-targets > graph.gexf
	@echo "Generated graph.gexf (open with Gephi)"

graphml: gexf

# Analysis targets
analyze: release
	.build/release/DependencyGraph "$(PROJECT)" --format analyze --show-targets

analyze-internal: release
	.build/release/DependencyGraph "$(PROJECT)" --format analyze --show-targets --internal-only
