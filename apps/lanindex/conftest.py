import sys

# main.py parses CLI args at import time; keep pytest's own args out of it.
sys.argv = sys.argv[:1]
