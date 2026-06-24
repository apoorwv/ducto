import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "python", "src"))

extensions = ["sphinx.ext.autodoc", "sphinx_markdown_builder"]
master_doc = "index"
exclude_patterns = ["_build"]
