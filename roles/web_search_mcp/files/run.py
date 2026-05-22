"""Workaround for https://github.com/nickclyde/duckduckgo-mcp-server/issues/45.

FastMCP auto-enables DNS rebinding protection when host="127.0.0.1" (the
module-level default used in server.py). Patching transport_security here,
before main() calls streamable_http_app(), prevents 421 Misdirected Request
when the service is accessed via a Docker service name or non-localhost IP.
"""
import duckduckgo_mcp_server.server as srv
from mcp.server.transport_security import TransportSecuritySettings

srv.mcp.settings.transport_security = TransportSecuritySettings(
    enable_dns_rebinding_protection=False
)

srv.main()