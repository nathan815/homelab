FROM mitmproxy/mitmproxy:11@sha256:e0deb0df7edf9f909053f274a067cd1cacb90f5c17d74459e1693179c0b98d8f
RUN pip install --no-cache-dir aiohttp==3.11.11 \
 && mkdir -p /ca-public /data \
 && chown mitmproxy:mitmproxy /ca-public /data
COPY addon.py ui.html /addon/
