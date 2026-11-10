"""tinyweb.win control plane.

Reserves a family slug, publishes DNS, orders the edge certificate, and issues
per-box Cloudflare Tunnel credentials. Family traffic does not pass through
this process.
"""

__version__ = "0.1.0"
